defmodule SddOrchestrator.AIRuntime.QuotasTest do
  @moduledoc "Task 3 proof for owner-scoped short-lived quota snapshots."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{PersonalConnections, Quotas, QuotaSnapshot}
  alias SddOrchestrator.AIRuntime.QuotaAdapter.RPC
  alias SddOrchestrator.QuotaAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]
  @live_source_version "codex-cli 0.live.18|schema:" <> String.duplicate("9", 64)

  setup do
    personal_ai_connection_fixture()
  end

  describe "owner refresh and minimized projection" do
    test "persists arbitrary buckets, reset, paid-continuation, token, and provenance facts",
         context do
      model_bucket =
        quota_bucket(%{
          id: "gpt-5-mini",
          scope: "model_specific",
          model: "gpt-5-mini",
          display_name: "GPT-5 mini",
          primary_window: %{
            used_percent: 91,
            resets_at: ~U[2026-08-03 13:30:00Z],
            duration_minutes: 300,
            unknown_fields: []
          },
          secondary_window: %{
            used_percent: 44,
            resets_at: ~U[2026-08-10 12:00:00Z],
            duration_minutes: 10_080,
            unknown_fields: []
          },
          credits: nil,
          paid_continuation: "unknown",
          spend_control: nil,
          spend_control_reached: nil,
          limit_reached_reason: "rate_limit_reached",
          unknown_fields: [
            "credits",
            "paid_continuation",
            "spend_control",
            "spend_control_reached"
          ]
        })

      result =
        quota_adapter_result(%{
          retrieved_at: @now,
          source_version: @live_source_version,
          buckets: [quota_bucket(), model_bucket]
        })

      assert {:ok, quota} = refresh(context, result)
      assert quota.connection_id == context.connection.id
      assert quota.authentication_mode == "chatgpt"
      assert quota.status == "reported"
      assert quota.expires_at == DateTime.add(@now, 300, :second)

      assert quota.provenance == %{
               source: "official_client",
               methods: ["account/rateLimits/read", "account/usage/read"],
               version: @live_source_version,
               retrieved_at: @now
             }

      assert Enum.map(quota.buckets, &{&1.scope, &1.id}) == [
               {"general", "general"},
               {"model_specific", "gpt-5-mini"}
             ]

      assert List.last(quota.buckets).secondary_window.used_percent == 44
      assert hd(quota.buckets).paid_continuation == "unknown"
      assert quota.reset_credits.available_count == 2
      assert quota.token_activity.lifetime_tokens == 12_000

      snapshot = Repo.one!(QuotaSnapshot)
      assert snapshot.account_id == context.account.id
      assert snapshot.connection_id == context.connection.id

      assert QuotaSnapshot.__schema__(:fields) |> Enum.sort() ==
               [
                 :account_id,
                 :authentication_mode,
                 :buckets,
                 :connection_id,
                 :expires_at,
                 :id,
                 :inserted_at,
                 :provider,
                 :reset_credits,
                 :retrieved_at,
                 :source,
                 :source_methods,
                 :source_version,
                 :status,
                 :token_activity,
                 :unknown_fields,
                 :updated_at
               ]

      safe_text = inspect(quota)
      refute safe_text =~ context.connection.worker_profile_ref

      for forbidden <- [
            :account_id,
            :worker_id,
            :worker_profile_ref,
            :provider_email,
            :provider_account_id,
            :provider_workspace_id,
            :plan,
            :plan_detail,
            :credential,
            :raw_error
          ] do
        refute Map.has_key?(quota, forbidden)
      end
    end

    test "keeps API-key quota and billing unknown in storage and projection", context do
      api_context =
        personal_ai_connection_fixture(%{
          account: context.account,
          worker: context.worker,
          label: "Personal API key",
          authentication_mode: "api_key",
          worker_profile_ref: "profile-api-key"
        })

      result =
        quota_adapter_result(%{authentication_mode: "api_key", retrieved_at: @now})

      assert {:ok, quota} = refresh(api_context, result)
      assert quota.status == "unknown"
      assert quota.authentication_mode == "api_key"
      assert quota.buckets == []
      assert quota.reset_credits == nil
      assert quota.token_activity == nil
      assert "api_key_quota" in quota.unknown_fields
      assert "api_key_billing" in quota.unknown_fields
    end

    test "requires current owner scope and an eligible active connection", context do
      result = quota_adapter_result(%{retrieved_at: @now})

      assert {:error, :not_found} =
               Quotas.current_quota(account_fixture(), context.connection.id, now: @now)

      assert {:ok, requested} =
               PersonalConnections.request_revocation(context.account, context.connection.id,
                 at: @now
               )

      assert {:error, :revoking} =
               Quotas.refresh(context.account, requested.id,
                 adapter: QuotaAdapterDouble,
                 adapter_result: {:ok, result},
                 notify: self(),
                 now: @now
               )

      refute_received {:quota_fetch, _, _}
      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end

    test "re-authorizes under lock after fetch before persistence", context do
      result = quota_adapter_result(%{retrieved_at: @now})

      assert {:error, :revoking} =
               Quotas.refresh(context.account, context.connection.id,
                 adapter: SddOrchestrator.RevokingQuotaAdapter,
                 adapter_result: {:ok, result},
                 now: @now
               )

      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end
  end

  describe "stale and failed evidence" do
    test "refuses stale source data and expired snapshots", context do
      stale = quota_adapter_result(%{retrieved_at: DateTime.add(@now, -301, :second)})
      assert {:error, :stale} = refresh(context, stale)
      assert Repo.aggregate(QuotaSnapshot, :count) == 0

      assert {:ok, _quota} =
               refresh(context, quota_adapter_result(%{retrieved_at: @now}))

      assert {:error, :stale} =
               Quotas.current_quota(context.account, context.connection.id,
                 now: DateTime.add(@now, 300, :second)
               )
    end

    test "a failed refresh invalidates all prior quota evidence", context do
      valid = quota_adapter_result(%{retrieved_at: @now})

      failures = [
        {{:ok, Map.put(valid, :provider_account_id, "provider-account-123")}, :invalid_response},
        {{:error, :incompatible}, :incompatible},
        {{:error, :worker_unavailable}, :worker_unavailable}
      ]

      for {adapter_result, expected_reason} <- failures do
        assert {:ok, _quota} = refresh(context, valid)

        assert {:error, ^expected_reason} =
                 Quotas.refresh(context.account, context.connection.id,
                   adapter: QuotaAdapterDouble,
                   adapter_result: adapter_result,
                   now: @now,
                   ttl_seconds: 300
                 )

        assert {:error, :unknown} =
                 Quotas.current_quota(context.account, context.connection.id, now: @now)
      end
    end

    test "serializes refreshes so an older success cannot restore evidence after a newer failure",
         context do
      owner = self()
      valid = quota_adapter_result(%{retrieved_at: @now})

      older =
        Task.async(fn ->
          receive do
            :start ->
              Quotas.refresh(context.account, context.connection.id,
                adapter: SddOrchestrator.BlockingQuotaAdapter,
                notify: owner,
                now: @now,
                ttl_seconds: 300
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), older.pid)
      send(older.pid, :start)
      assert_receive {:blocking_quota_fetch, older_pid, true}, 1_000
      assert older_pid == older.pid

      newer =
        Task.async(fn ->
          receive do
            :start ->
              Quotas.refresh(context.account, context.connection.id,
                adapter: SddOrchestrator.BlockingQuotaAdapter,
                notify: owner,
                now: @now,
                ttl_seconds: 300
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), newer.pid)
      send(newer.pid, :start)
      newer_task_pid = newer.pid
      refute_receive {:blocking_quota_fetch, ^newer_task_pid, true}, 50

      send(older.pid, {:quota_adapter_result, {:ok, valid}})
      assert {:ok, _quota} = Task.await(older)

      assert_receive {:blocking_quota_fetch, newer_pid, true}, 1_000
      assert newer_pid == newer.pid
      send(newer.pid, {:quota_adapter_result, {:error, :worker_unavailable}})
      assert {:error, :worker_unavailable} = Task.await(newer)

      assert Repo.aggregate(QuotaSnapshot, :count) == 0

      assert {:error, :unknown} =
               Quotas.current_quota(context.account, context.connection.id, now: @now)
    end

    test "normalizes advisory-lock acquisition failures without contacting the worker", context do
      assert {:error, :worker_unavailable} =
               Quotas.refresh(context.account, context.connection.id,
                 adapter: QuotaAdapterDouble,
                 adapter_result: {:ok, quota_adapter_result(%{retrieved_at: @now})},
                 refresh_lock: fn _account_id, _connection_id, _fun ->
                   {:lock_error, :database_unavailable}
                 end,
                 now: @now
               )

      refute_received {:quota_fetch, _account, _connection}
    end

    test "revalidates persisted provenance and authentication binding", context do
      assert {:ok, _quota} =
               refresh(context, quota_adapter_result(%{retrieved_at: @now}))

      Repo.update_all(QuotaSnapshot, set: [source_methods: ["provider/account/raw"]])

      assert {:error, :unknown} =
               Quotas.current_quota(context.account, context.connection.id, now: @now)
    end
  end

  describe "strict adapter and RPC validation" do
    test "rejects malformed, oversized, duplicate, credential-shaped, and profile-shaped facts",
         context do
      safe = quota_adapter_result(%{retrieved_at: @now})
      bucket = hd(safe.buckets)

      invalid_results = [
        Map.put(safe, :provider_email, "provider@example.test"),
        %{safe | provider: "other"},
        %{safe | source: "model_self_report"},
        %{safe | source_methods: ["account/read"]},
        %{safe | source_version: "worker-reported-version"},
        %{safe | source_version: String.duplicate("x", 201)},
        %{safe | buckets: [Map.put(bucket, :plan, "pro")]},
        %{safe | buckets: [%{bucket | display_name: "provider@example.test"}]},
        %{safe | buckets: [%{bucket | display_name: "Bearer worker-secret"}]},
        %{safe | buckets: [%{bucket | display_name: "provider-account-123"}]},
        %{safe | buckets: [%{bucket | display_name: "provider-workspace-456"}]},
        %{safe | buckets: [%{bucket | display_name: "raw provider failure"}]},
        %{safe | buckets: [%{bucket | id: context.connection.worker_profile_ref}]},
        %{safe | buckets: [bucket, bucket]},
        %{safe | buckets: Enum.map(1..65, &unique_bucket/1)},
        %{safe | unknown_fields: ["raw error"]},
        %{safe | status: "unknown", source_methods: []},
        %{safe | source_methods: ["account/rateLimits/read"]},
        %{safe | source_methods: ["account/usage/read"]}
      ]

      for result <- invalid_results do
        assert {:error, :invalid_response} = refresh(context, result)
      end

      assert Repo.aggregate(QuotaSnapshot, :count) == 0
    end

    test "the production RPC sends the exact quota/1 request and validates output", context do
      connection = Repo.preload(context.connection, :worker)
      result = quota_adapter_result(%{retrieved_at: @now})

      string_result = result |> Jason.encode!() |> Jason.decode!()

      assert {:ok, normalized} =
               RPC.fetch(context.account, connection,
                 rpc: QuotaAdapterDouble,
                 rpc_result: {:ok, string_result},
                 notify: self()
               )

      assert hd(normalized.buckets).id == "general"

      assert_received {:quota_rpc_request, account_id, workspace_id, worker_id, "quota/1", params}

      assert account_id == context.account.id
      assert workspace_id == context.worker.device_workspace_id
      assert worker_id == context.worker.id

      assert params == %{
               "operation" => "refresh",
               "connection_ref" => context.connection.worker_profile_ref,
               "provider" => "openai_codex",
               "authentication_mode" => "chatgpt"
             }

      refute Map.has_key?(normalized, :connection_ref)
      refute inspect(normalized) =~ context.connection.worker_profile_ref

      assert {:error, :invalid_response} =
               RPC.fetch(context.account, connection,
                 rpc: QuotaAdapterDouble,
                 rpc_result: {:ok, Map.put(string_result, "plan", "pro")}
               )
    end

    test "the deterministic adapter receives the re-authorized owner and connection", context do
      result = quota_adapter_result(%{retrieved_at: @now})

      assert {:ok, _quota} =
               Quotas.refresh(context.account, context.connection.id,
                 adapter: QuotaAdapterDouble,
                 adapter_result: {:ok, result},
                 notify: self(),
                 now: @now
               )

      assert_received {:quota_fetch, account, connection}
      assert account.id == context.account.id
      assert connection.id == context.connection.id
      assert connection.worker.id == context.worker.id
    end

    test "database enforces connection ownership and one current snapshot", context do
      result = quota_adapter_result(%{retrieved_at: @now})
      assert {:ok, _quota} = refresh(context, result)
      snapshot = Repo.one!(QuotaSnapshot)
      attrs = snapshot_attrs(snapshot)
      assert Repo.aggregate(QuotaSnapshot, :count) == 1

      assert {:error, duplicate_changeset} =
               %QuotaSnapshot{}
               |> QuotaSnapshot.create_changeset(attrs)
               |> Repo.insert()

      assert "has already been taken" in errors_on(duplicate_changeset).connection_id

      other_account = account_fixture()

      assert {:error, ownership_changeset} =
               %QuotaSnapshot{}
               |> QuotaSnapshot.create_changeset(%{attrs | account_id: other_account.id})
               |> Repo.insert()

      assert "does not exist" in errors_on(ownership_changeset).connection_id

      assert {:ok, _replacement} = refresh(context, result)
      assert Repo.aggregate(QuotaSnapshot, :count) == 1
    end
  end

  defp refresh(context, result) do
    Quotas.refresh(context.account, context.connection.id,
      adapter: QuotaAdapterDouble,
      adapter_result: {:ok, result},
      now: @now,
      ttl_seconds: 300
    )
  end

  defp unique_bucket(index) do
    quota_bucket(%{
      id: "provider-bucket-#{index}",
      display_name: "Provider bucket #{index}"
    })
  end

  defp snapshot_attrs(snapshot) do
    Map.take(snapshot, [
      :account_id,
      :connection_id,
      :provider,
      :authentication_mode,
      :status,
      :source,
      :source_methods,
      :source_version,
      :retrieved_at,
      :expires_at,
      :buckets,
      :reset_credits,
      :token_activity,
      :unknown_fields
    ])
  end
end

defmodule SddOrchestrator.RevokingQuotaAdapter do
  @moduledoc false

  @behaviour SddOrchestrator.AIRuntime.QuotaAdapter

  @impl true
  def fetch(account, connection, opts) do
    {:ok, _connection} =
      SddOrchestrator.AIRuntime.PersonalConnections.request_revocation(
        account,
        connection.id,
        at: Keyword.get(opts, :now)
      )

    Keyword.fetch!(opts, :adapter_result)
  end
end

defmodule SddOrchestrator.BlockingQuotaAdapter do
  @moduledoc false

  @behaviour SddOrchestrator.AIRuntime.QuotaAdapter

  @impl true
  def fetch(_account, _connection, opts) do
    notify = Keyword.fetch!(opts, :notify)

    {:ok, %{rows: [[advisory_lock_held?]]}} =
      SddOrchestrator.Repo.query("""
      SELECT EXISTS (
        SELECT 1
        FROM pg_locks
        WHERE locktype = 'advisory'
          AND pid = pg_backend_pid()
          AND granted
      )
      """)

    send(notify, {:blocking_quota_fetch, self(), advisory_lock_held?})

    receive do
      {:quota_adapter_result, result} -> result
    end
  end
end
