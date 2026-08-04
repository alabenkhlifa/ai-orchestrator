defmodule SddOrchestrator.AIRuntime.SnapshotExpiryTest do
  @moduledoc """
  Task 16 proof that catalog and quota snapshots expire instead of becoming
  durable entitlements.

  Covers the configured short lifetime and its maximum, the exact boundary
  between current and expired evidence, refresh before session creation,
  terminal-connection cleanup and cascade, the supervised idempotent sweep with
  its own advisory lock, and the rights integration for both entities.

  Advisory-locked sweeps are session-scoped and the lifetime is read from
  application environment, so this proof runs serially.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    ModelCatalogs,
    ModelCatalogSnapshot,
    PersonalAIConnection,
    PersonalConnectionRevocations,
    PersonalConnections,
    Quotas,
    QuotaSnapshot,
    RuntimeSessions
  }

  alias SddOrchestrator.ModelCatalogAdapterDouble
  alias SddOrchestrator.PersonalConnectionAdapterDouble
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner, Rights}
  alias SddOrchestrator.QuotaAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]
  @ttl 300
  @expires_at DateTime.add(@now, @ttl, :second)
  @max_ttl 3_600

  @confirming [adapter: PersonalConnectionAdapterDouble]

  setup do
    context = runtime_session_context_fixture(%{now: @now, ttl_seconds: @ttl})

    %{
      account: context.account,
      connection: context.connection,
      worker: context.worker,
      catalog: context.catalog,
      quota: context.quota
    }
  end

  describe "configured short lifetime" do
    test "both snapshots carry the lifetime derived from the source retrieval time", context do
      assert context.catalog.expires_at == @expires_at
      assert context.catalog.provenance.retrieved_at == @now
      assert context.quota.expires_at == @expires_at
      assert context.quota.provenance.retrieved_at == @now
    end

    test "a configured non-default lifetime replaces the default for both kinds", context do
      put_ttl(:model_catalog_ttl_seconds, 60)
      put_ttl(:quota_snapshot_ttl_seconds, 90)

      assert {:ok, catalog} = refresh_catalog(context, @now, [])
      assert catalog.expires_at == DateTime.add(@now, 60, :second)

      assert {:ok, quota} = refresh_quota(context, @now, [])
      assert quota.expires_at == DateTime.add(@now, 90, :second)

      assert {:error, :stale} =
               ModelCatalogs.current_catalog(context.account, context.connection.id,
                 now: DateTime.add(@now, 60, :second)
               )

      assert {:error, :stale} =
               Quotas.current_quota(context.account, context.connection.id,
                 now: DateTime.add(@now, 90, :second)
               )
    end

    test "a lifetime beyond the maximum is refused and invalidates prior evidence", context do
      assert {:error, :invalid_request} =
               refresh_catalog(context, @now, ttl_seconds: @max_ttl + 1)

      assert {:error, :invalid_request} = refresh_quota(context, @now, ttl_seconds: @max_ttl + 1)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end

    test "a misconfigured deployment lifetime fails the refresh closed", context do
      put_ttl(:model_catalog_ttl_seconds, @max_ttl + 1)
      put_ttl(:quota_snapshot_ttl_seconds, 0)

      assert {:error, :invalid_request} = refresh_catalog(context, @now, [])
      assert {:error, :invalid_request} = refresh_quota(context, @now, [])

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end

    test "the maximum lifetime itself is still accepted", context do
      assert {:ok, catalog} = refresh_catalog(context, @now, ttl_seconds: @max_ttl)
      assert catalog.expires_at == DateTime.add(@now, @max_ttl, :second)

      assert {:ok, quota} = refresh_quota(context, @now, ttl_seconds: @max_ttl)
      assert quota.expires_at == DateTime.add(@now, @max_ttl, :second)
    end
  end

  describe "current versus expired evidence" do
    test "a catalog is current one second before expiry and refused from that instant",
         context do
      just_before = DateTime.add(@expires_at, -1, :second)

      assert {:ok, catalog} =
               ModelCatalogs.current_catalog(context.account, context.connection.id,
                 now: just_before
               )

      assert catalog.expires_at == @expires_at
      assert {:ok, selection} = validate_selection(context, just_before)
      assert selection.model == "codex-test-model"

      assert {:error, :stale} =
               ModelCatalogs.current_catalog(context.account, context.connection.id,
                 now: @expires_at
               )

      assert {:error, :stale} = validate_selection(context, @expires_at)

      assert {:error, :stale} =
               ModelCatalogs.current_catalog(context.account, context.connection.id,
                 now: DateTime.add(@expires_at, 1, :second)
               )

      assert {:error, :stale} = validate_selection(context, DateTime.add(@expires_at, 1, :second))
    end

    test "a quota is current one second before expiry and refused from that instant", context do
      just_before = DateTime.add(@expires_at, -1, :second)

      assert {:ok, quota} =
               Quotas.current_quota(context.account, context.connection.id, now: just_before)

      assert quota.expires_at == @expires_at

      assert {:error, :stale} =
               Quotas.current_quota(context.account, context.connection.id, now: @expires_at)

      assert {:error, :stale} =
               Quotas.current_quota(context.account, context.connection.id,
                 now: DateTime.add(@expires_at, 1, :second)
               )
    end

    test "expired catalog evidence cannot pin a runtime session until it is refreshed",
         context do
      request = runtime_session_request(context)

      assert {:error, :stale} =
               RuntimeSessions.pin_session(context.account, request, now: @expires_at)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0

      assert {:ok, _catalog} = refresh_catalog(context, @expires_at, ttl_seconds: @ttl)
      assert {:ok, _quota} = refresh_quota(context, @expires_at, ttl_seconds: @ttl)

      assert {:ok, session} =
               RuntimeSessions.pin_session(context.account, request, now: @expires_at)

      assert session.connection_id == context.connection.id
      assert session.model == "codex-test-model"
    end

    test "a refresh after expiry replaces the expired row with current evidence", context do
      later = DateTime.add(@expires_at, 100, :second)

      assert {:error, :stale} =
               ModelCatalogs.current_catalog(context.account, context.connection.id, now: later)

      assert {:ok, catalog} = refresh_catalog(context, later, ttl_seconds: @ttl)
      assert catalog.expires_at == DateTime.add(later, @ttl, :second)

      assert {:ok, quota} = refresh_quota(context, later, ttl_seconds: @ttl)
      assert quota.expires_at == DateTime.add(later, @ttl, :second)

      assert {:ok, _current} =
               ModelCatalogs.current_catalog(context.account, context.connection.id, now: later)

      assert {:ok, _current} =
               Quotas.current_quota(context.account, context.connection.id, now: later)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 1
      assert Repo.aggregate(QuotaSnapshot, :count) == 1
    end
  end

  describe "supervised expiry sweep" do
    test "the sweep keeps evidence that is still current", context do
      just_before = DateTime.add(@expires_at, -1, :second)

      assert %{expired_model_catalog_snapshots: 0, expired_quota_snapshots: 0} =
               Retention.prune_ai_runtime_snapshots(just_before)

      assert {:ok, _catalog} =
               ModelCatalogs.current_catalog(context.account, context.connection.id,
                 now: just_before
               )

      assert {:ok, _quota} =
               Quotas.current_quota(context.account, context.connection.id, now: just_before)
    end

    test "the whole pruner deletes expired evidence and is idempotent", _context do
      assert %{expired_model_catalog_snapshots: 1, expired_quota_snapshots: 1} =
               Retention.prune_all(@expires_at)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
      assert Repo.aggregate(QuotaSnapshot, :count) == 0

      assert %{expired_model_catalog_snapshots: 0, expired_quota_snapshots: 0} =
               Retention.prune_all(@expires_at)

      assert %{expired_model_catalog_snapshots: 0, expired_quota_snapshots: 0} =
               Retention.prune_ai_runtime_snapshots(@expires_at)
    end

    test "the sweep purges evidence for a connection that has become terminal", context do
      assert {:ok, acknowledged} =
               PersonalConnections.request_revocation(
                 context.account,
                 context.connection.id,
                 [at: @now] ++ @confirming
               )

      assert acknowledged.revocation_state == "acknowledged"
      assert acknowledged.deletion_scheduled_at
      assert DateTime.compare(acknowledged.deletion_scheduled_at, @now) == :gt

      # The evidence has not expired yet; the terminal connection is the reason.
      assert %{expired_model_catalog_snapshots: 1, expired_quota_snapshots: 1} =
               Retention.prune_all(@now)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
      assert Repo.aggregate(QuotaSnapshot, :count) == 0

      # The opaque reference itself still serves its own retention window.
      assert Repo.get(PersonalAIConnection, context.connection.id)

      assert {:error, :unknown} =
               ModelCatalogs.current_catalog(context.account, context.connection.id, now: @now)

      assert {:error, :unknown} =
               Quotas.current_quota(context.account, context.connection.id, now: @now)
    end

    test "deleting a connection cascades to its catalog and quota evidence", context do
      other = runtime_session_context_fixture(%{now: @now, ttl_seconds: @ttl})

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 2
      assert Repo.aggregate(QuotaSnapshot, :count) == 2

      Repo.delete!(Repo.get!(PersonalAIConnection, context.connection.id))

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 1
      assert Repo.aggregate(QuotaSnapshot, :count) == 1

      assert {:ok, _catalog} =
               ModelCatalogs.current_catalog(other.account, other.connection.id, now: @now)
    end

    test "a contended sweep yields, deletes nothing, and the next pass converges", _context do
      holder = start_lock_holder()

      assert :locked = Retention.prune_ai_runtime_snapshots(@expires_at)
      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 1
      assert Repo.aggregate(QuotaSnapshot, :count) == 1

      assert %{expired_model_catalog_snapshots: 0, expired_quota_snapshots: 0} =
               Retention.prune_all(@expires_at)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 1
      assert Repo.aggregate(QuotaSnapshot, :count) == 1

      release_lock_holder(holder)

      assert %{expired_model_catalog_snapshots: 1, expired_quota_snapshots: 1} =
               Retention.prune_ai_runtime_snapshots(@expires_at)

      assert %{expired_model_catalog_snapshots: 0, expired_quota_snapshots: 0} =
               Retention.prune_ai_runtime_snapshots(@expires_at)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end

    test "the sweep contends on its own advisory lock key", _context do
      key = Retention.snapshot_advisory_lock_key()

      assert key > 0
      refute key == PersonalConnectionRevocations.advisory_lock_key()
      refute key == RetentionPruner.advisory_lock_key()
    end
  end

  describe "rights integration" do
    test "account erasure leaves no catalog or quota evidence", context do
      other = runtime_session_context_fixture(%{now: @now, ttl_seconds: @ttl})

      assert {:ok, _erasure} =
               Rights.erase_account(context.account.id, [at: @now] ++ @confirming)

      assert Repo.aggregate(PersonalAIConnection, :count) == 1
      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 1
      assert Repo.aggregate(QuotaSnapshot, :count) == 1

      assert {:ok, _catalog} =
               ModelCatalogs.current_catalog(other.account, other.connection.id, now: @now)

      assert {:ok, _erasure} = Rights.erase_account(other.account.id, [at: @now] ++ @confirming)

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end

    test "personal AI service termination leaves no evidence in its scope", context do
      other = runtime_session_context_fixture(%{now: @now, ttl_seconds: @ttl})

      assert {:ok, termination} =
               Rights.terminate_personal_ai_service(
                 [at: @now, account: context.account] ++ @confirming
               )

      assert termination.personal_ai_snapshots == %{model_catalogs: 1, quotas: 1}

      assert {:error, :unknown} =
               ModelCatalogs.current_catalog(context.account, context.connection.id, now: @now)

      assert {:error, :unknown} =
               Quotas.current_quota(context.account, context.connection.id, now: @now)

      assert {:ok, _catalog} =
               ModelCatalogs.current_catalog(other.account, other.connection.id, now: @now)

      assert {:ok, repeated} =
               Rights.terminate_personal_ai_service(
                 [at: @now, account: context.account] ++ @confirming
               )

      assert repeated.personal_ai_snapshots == %{model_catalogs: 0, quotas: 0}
    end

    test "the access export reports both snapshot entities explicitly", context do
      assert {:ok, export} = Rights.export_account(context.account.id)

      assert [catalog] = export.model_catalog_snapshots
      assert catalog.connection_id == context.connection.id
      assert catalog.provider == "openai_codex"
      assert catalog.status == "enumerated"
      assert catalog.retrieved_at == @now
      assert catalog.expires_at == @expires_at
      assert [%{"model" => "codex-test-model"}] = catalog.models

      assert [quota] = export.quota_snapshots
      assert quota.connection_id == context.connection.id
      assert quota.authentication_mode == "chatgpt"
      assert quota.expires_at == @expires_at
      assert [%{"id" => "general"}] = quota.buckets

      refute inspect(export) =~ context.connection.worker_profile_ref
    end

    test "the access export names both entities even when nothing is held", _context do
      account = account_fixture()

      assert {:ok, export} = Rights.export_account(account.id)
      assert export.model_catalog_snapshots == []
      assert export.quota_snapshots == []
    end
  end

  defp validate_selection(context, now) do
    ModelCatalogs.validate_selection(
      context.account,
      context.connection.id,
      "codex-test-model",
      "medium",
      now: now
    )
  end

  defp refresh_catalog(context, now, opts) do
    ModelCatalogs.refresh(
      context.account,
      context.connection.id,
      [
        adapter: ModelCatalogAdapterDouble,
        adapter_result: {:ok, model_catalog_adapter_result(%{retrieved_at: now})},
        now: now
      ] ++ opts
    )
  end

  defp refresh_quota(context, now, opts) do
    Quotas.refresh(
      context.account,
      context.connection.id,
      [
        adapter: QuotaAdapterDouble,
        adapter_result:
          {:ok,
           quota_adapter_result(%{
             authentication_mode: context.connection.authentication_mode,
             retrieved_at: now
           })},
        now: now
      ] ++ opts
    )
  end

  defp put_ttl(key, value) do
    previous = Application.fetch_env(:sdd_orchestrator, key)
    Application.put_env(:sdd_orchestrator, key, value)

    on_exit(fn ->
      case previous do
        {:ok, restored} -> Application.put_env(:sdd_orchestrator, key, restored)
        :error -> Application.delete_env(:sdd_orchestrator, key)
      end
    end)
  end

  # The sweep's lock is session-scoped and re-entrant within one session, so the
  # shared sandbox connection cannot stand in for a competing instance.
  defp start_lock_holder do
    {:ok, holder} = Postgrex.start_link(postgrex_options())
    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: GenServer.stop(holder) end)

    assert %Postgrex.Result{rows: [[:void]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [
               Retention.snapshot_advisory_lock_key()
             ])

    holder
  end

  defp release_lock_holder(holder) do
    assert %Postgrex.Result{rows: [[true]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [
               Retention.snapshot_advisory_lock_key()
             ])
  end

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
