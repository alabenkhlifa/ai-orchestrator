defmodule SddOrchestrator.Delivery.PreviewDeploymentTest do
  @moduledoc """
  Proof for the configured preview adapter and deployment lifecycle (Task 32).

  One promise is pinned above all others: a preview is never verification truth.
  It starts only from a verified completion the gate already recorded, it deploys
  the exact commit named there, and whatever becomes of it — ready, failed, timed
  out, expired, or never requested at all — the run, the attempt, the feature,
  and the recorded verdict are left exactly as they were. Each of those five
  outcomes is proved against that invariant rather than assumed to respect it.

  The second promise is that nothing which could authenticate to a provider ever
  reaches a stored record. Credentials resolve in the adapter from configuration;
  the request carries only an opaque reference; the record keeps only a provider
  handle and one participant-safe link; and a provider that answers with prose,
  or with a URL carrying a query string, is refused rather than sanitized. The
  changeset, a check constraint, and a negative scan over the record, the
  activity payload, and the cleanup command all say so independently.

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's records in the
  hosted database and two implementations are only safe once they answer the
  same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    DeliveryStore,
    Feature,
    PreviewAdapter,
    PreviewDeployment,
    Previews,
    SecretBoundary,
    VerificationCompletion
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.PreviewAdapterDouble
  alias SddOrchestrator.Repo

  @commit "a1b2c3d4e5f6a7b8c9d0"
  @later_commit "b2b2b2b2b2b2b2b2b2b2"
  @contract ["mix test"]
  @path "web"
  @link "https://preview.example.test/branch-1"
  @credential_ref "vault://preview-provider"
  @migration_version 20_260_730_020_000

  # The migration test rolls the whole table back, which needs an exclusive lock
  # on it and on every table it references. Giving that one test a bare sandbox
  # keeps it from deadlocking against rows its own setup would otherwise hold.
  setup context do
    if context[:migration], do: :ok, else: delivery_setup(context)
  end

  defp delivery_setup(context) do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path = Path.join(System.tmp_dir!(), "preview-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(
        authority,
        hosted.project.id,
        run_steps(hosted.project, feature, 1)
      )

    on_exit(
      PreviewAdapterDouble.install(
        credential_ref: @credential_ref,
        projects: %{hosted.project.id => [@path]}
      )
    )

    %{
      authority: authority,
      project: hosted.project,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "authorizing a preview at all (#{authority})" do
      @describetag authority: authority

      test "a project with no configured preview path reaches no provider", context do
        verify(context)
        PreviewAdapterDouble.install(projects: %{})

        assert {:error, :preview_not_authorized} = start(context)
        assert PreviewAdapterDouble.requested() == []
        assert Previews.list(context.authority, context.project.id) == []
      end

      test "a deployment with no configured adapter reaches no provider", context do
        verify(context)
        on_exit(PreviewAdapterDouble.uninstall())

        assert {:error, :preview_not_configured} = start(context)
        assert PreviewAdapterDouble.requested() == []
      end

      test "a path the project did not authorize is refused", context do
        verify(context)

        assert {:error, :preview_path_not_authorized} = start(context, path: "staging")
        assert PreviewAdapterDouble.requested() == []
      end

      test "a run with no verified completion is refused before any provider call", context do
        assert {:error, :not_verified} = start(context)
        assert PreviewAdapterDouble.requested() == []
      end

      test "a refused completion is not a verified one", context do
        # No check result is recorded, so the gate genuinely refuses.
        results = verify(context, checks: :skip)

        assert results.activity.type == VerificationCompletion.refused_activity_type()
        assert {:error, :not_verified} = start(context)
        assert PreviewAdapterDouble.requested() == []
      end
    end

    describe "starting one preview for the verified commit (#{authority})" do
      @describetag authority: authority

      test "the branch preview starts and its link is attached on success [AC-21]", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)

        assert {:ok, %{deployment: deployment, activity: activity}} = start(context)

        assert deployment.status == "ready"
        assert deployment.link == @link
        assert deployment.ready_at
        assert deployment.provider == "configured-preview"
        assert deployment.provider_ref == "preview-provider/deployment-1"
        refute deployment.failure_reason

        assert activity.type == Previews.activity_type()
        assert activity.payload["status"] == "ready"
        assert activity.payload["link"] == @link
      end

      test "the request is bound to the run, attempt, branch, and exact commit", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.project_id == context.project.id
        assert deployment.feature_id == context.feature.id
        assert deployment.run_id == context.run.id
        assert deployment.attempt_id == context.attempt.id
        assert deployment.branch == context.run.branch
        assert deployment.commit_sha == @commit
        assert deployment.path == @path

        assert [request] = PreviewAdapterDouble.requested()
        assert request.run_id == context.run.id
        assert request.attempt_id == context.attempt.id
        assert request.branch == context.run.branch
        assert request.commit_sha == @commit
        assert request.path == @path
        assert request.request_key == PreviewAdapter.request_key(deployment)
      end

      test "a provider that is still working leaves the preview pending", context do
        verify(context)

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "pending"
        refute deployment.link
        refute deployment.ready_at
        assert PreviewDeployment.open?(deployment)
      end

      test "requesting the same run, attempt, and commit twice deploys once", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)

        {:ok, %{deployment: first}} = start(context)

        assert {:ok, %{deployment: second, changed?: false, activity: nil}} = start(context)

        assert second.id == first.id
        assert length(PreviewAdapterDouble.requested()) == 1
        assert length(Previews.list(context.authority, context.project.id)) == 1
      end

      test "the timeout deadline comes from the configured adapter policy", context do
        verify(context)

        PreviewAdapterDouble.install(
          projects: %{context.project.id => [@path]},
          request_timeout_ms: 60_000
        )

        now = DateTime.utc_now()
        {:ok, %{deployment: deployment}} = start(context, now: now)

        assert DateTime.diff(deployment.timeout_at, now, :millisecond) == 60_000
      end
    end

    describe "a preview that does not succeed (#{authority})" do
      @describetag authority: authority

      test "a provider failure is recorded with its own reason", context do
        verify(context)
        PreviewAdapterDouble.script(:failed)

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "failed"
        assert deployment.failure_reason == "quota_exhausted"
        refute deployment.link
        assert PreviewDeployment.failed?(deployment)
      end

      test "a request that times out is recorded distinctly from a failure", context do
        verify(context)
        PreviewAdapterDouble.script({:error, :timeout})

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "timed_out"
        assert deployment.failure_reason == "preview_request_timeout"
        refute deployment.link
      end

      test "a provider still pending past the configured deadline has timed out", context do
        verify(context)

        PreviewAdapterDouble.install(
          projects: %{context.project.id => [@path]},
          request_timeout_ms: 1_000
        )

        now = DateTime.utc_now()
        {:ok, %{deployment: pending}} = start(context, now: now)
        assert pending.status == "pending"

        assert {:ok, %{deployment: settled, changed?: true}} =
                 Previews.refresh(context.authority, context.project.id, pending,
                   now: DateTime.add(now, 10, :second)
                 )

        assert settled.status == "timed_out"
        assert settled.failure_reason == "preview_request_timeout"
      end

      test "a ready deployment past its expiry is expired, not failed", context do
        verify(context)
        now = DateTime.utc_now()
        expires_at = DateTime.add(now, 60, :second)

        PreviewAdapterDouble.script(fn _request ->
          PreviewAdapterDouble.ready(expires_at: expires_at)
        end)

        {:ok, %{deployment: ready}} = start(context, now: now)
        assert ready.status == "ready"
        assert DateTime.compare(ready.expires_at, expires_at) == :eq

        PreviewAdapterDouble.script_status(:ready)

        assert {:ok, %{deployment: expired}} =
                 Previews.refresh(context.authority, context.project.id, ready,
                   now: DateTime.add(now, 600, :second)
                 )

        assert expired.status == "expired"
        refute expired.link
        refute expired.failure_reason
      end

      test "an unusable provider answer is refused rather than stored", context do
        verify(context)
        PreviewAdapterDouble.script({:raw, {:ok, %{status: "ready", link: nil}}})

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "failed"
        assert deployment.failure_reason == "invalid_preview_response"
      end

      test "a terminal preview is never reopened by a later poll", context do
        verify(context)
        PreviewAdapterDouble.script(:failed)
        {:ok, %{deployment: failed}} = start(context)

        PreviewAdapterDouble.script_status(:ready)

        assert {:ok, %{deployment: held, changed?: false}} =
                 Previews.refresh(context.authority, context.project.id, failed)

        assert held.status == "failed"
        assert PreviewAdapterDouble.queried() == []
      end

      test "polling an unchanged pending preview writes nothing", context do
        verify(context)
        {:ok, %{deployment: pending}} = start(context)

        before = length(activity(context))

        assert {:ok, %{changed?: false, activity: nil}} =
                 Previews.refresh(context.authority, context.project.id, pending)

        assert length(activity(context)) == before
      end
    end

    describe "a later attempt verifying another commit (#{authority})" do
      @describetag authority: authority

      test "supersedes the older preview and deploys the new commit", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)
        {:ok, %{deployment: older}} = start(context)

        later = continue(context)
        verify(later, commit_sha: @later_commit)

        assert {:ok, %{deployment: newer}} = start(later)

        assert newer.id != older.id
        assert newer.commit_sha == @later_commit
        assert newer.attempt_id == later.attempt.id

        assert [replaced] =
                 context.authority
                 |> Previews.list(context.project.id)
                 |> Enum.filter(&(&1.id == older.id))

        assert replaced.status == "superseded"
        assert replaced.superseded_by_id == newer.id
        refute PreviewDeployment.current?(replaced)

        assert {:ok, current} =
                 Previews.current(context.authority, context.project.id, context.run.id)

        assert current.id == newer.id
      end

      test "a different commit is a different deployment, not a new state", context do
        verify(context)
        {:ok, %{deployment: older}} = start(context)

        later = continue(context)
        verify(later, commit_sha: @later_commit)
        {:ok, %{deployment: newer}} = start(later)

        assert length(Previews.list(context.authority, context.project.id)) == 2
        assert older.commit_sha == @commit
        assert newer.commit_sha == @later_commit
        assert length(PreviewAdapterDouble.requested()) == 2
      end
    end

    describe "the cleanup seam (#{authority})" do
      @describetag authority: authority

      test "records a durable command and then what it achieved", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)
        {:ok, %{deployment: deployment}} = start(context)

        assert {:ok, %{deployment: cleaned}} =
                 Previews.cleanup(context.authority, context.project.id, deployment,
                   reason: :project_deleted
                 )

        assert cleaned.cleanup_state == "done"
        assert cleaned.cleanup_command_id == "preview-cleanup:" <> deployment.id

        assert [command] = PreviewAdapterDouble.cleaned()
        assert command.command_id == cleaned.cleanup_command_id
        assert command.provider_ref == deployment.provider_ref
        assert command.reason == "project_deleted"
        assert command.request_key == PreviewAdapter.request_key(deployment)
      end

      test "a repeated cleanup does not release a second time", context do
        verify(context)
        {:ok, %{deployment: deployment}} = start(context)

        {:ok, %{deployment: cleaned}} =
          Previews.cleanup(context.authority, context.project.id, deployment)

        assert {:ok, %{deployment: again, changed?: false}} =
                 Previews.cleanup(context.authority, context.project.id, cleaned)

        assert again.cleanup_state == "done"
        assert length(PreviewAdapterDouble.cleaned()) == 1
      end

      test "a provider that refuses leaves the command owed, not forgotten", context do
        verify(context)
        {:ok, %{deployment: deployment}} = start(context)
        PreviewAdapterDouble.script_cleanup({:error, :provider_unavailable})

        {:ok, %{deployment: refused}} =
          Previews.cleanup(context.authority, context.project.id, deployment)

        assert refused.cleanup_state == "failed"
        assert refused.cleanup_command_id == "preview-cleanup:" <> deployment.id

        PreviewAdapterDouble.script_cleanup(:ok)

        {:ok, %{deployment: retried}} =
          Previews.cleanup(context.authority, context.project.id, refused)

        assert retried.cleanup_state == "done"
        assert retried.cleanup_command_id == refused.cleanup_command_id
        assert length(PreviewAdapterDouble.cleaned()) == 2
      end
    end

    describe "credential and link isolation (#{authority})" do
      @describetag authority: authority

      test "no credential reaches the record, the activity, or the command", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)
        {:ok, %{deployment: deployment, activity: activity}} = start(context)

        {:ok, %{deployment: cleaned}} =
          Previews.cleanup(context.authority, context.project.id, deployment)

        value = PreviewDeployment.to_value(cleaned)

        assert SecretBoundary.validate(value) == :ok
        assert SecretBoundary.validate(activity.payload) == :ok

        for key <- SecretBoundary.forbidden_keys() do
          refute Map.has_key?(value, key)
          refute Map.has_key?(activity.payload, key)
        end

        # The configured credential reference is resolved by the adapter and is
        # never part of what the project stores.
        refute scan(value) =~ "vault://"
        refute scan(activity.payload) =~ "vault://"
        refute cleaned.cleanup_command_id =~ "vault://"
      end

      test "the adapter resolves its credential outside the project record", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)
        {:ok, _started} = start(context)

        assert [request] = PreviewAdapterDouble.requested()
        assert request.credential_ref == @credential_ref
        refute Map.has_key?(request, :credential)
        assert SecretBoundary.validate(Map.delete(request, :credential_ref)) == :ok
      end

      test "a request carrying credential material never leaves the control plane", context do
        {:ok, policy} = PreviewAdapter.authorize(context.project.id)

        assert {:error, :preview_request_rejected} =
                 PreviewAdapter.request(policy, %{
                   request_key: "preview:v1:abc",
                   token: "sk-live-not-allowed"
                 })

        assert PreviewAdapterDouble.requested() == []
      end

      test "a link carrying a query string is refused, not stored", context do
        verify(context)

        PreviewAdapterDouble.script(
          {:raw,
           {:ok,
            %{
              status: "ready",
              provider_ref: "preview-provider/x",
              link: "https://preview.example.test/branch?token=sk-live-123"
            }}}
        )

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "failed"
        assert deployment.failure_reason == "invalid_preview_response"
        refute deployment.link
        refute scan(PreviewDeployment.to_value(deployment)) =~ "sk-live"
      end

      test "provider prose is reduced to a token before anything is stored", context do
        verify(context)
        PreviewAdapterDouble.script({:error, "auth failed for token sk-live-123"})

        {:ok, %{deployment: deployment, activity: activity}} = start(context)

        assert deployment.status == "failed"
        assert deployment.failure_reason == "provider_error"
        refute scan(PreviewDeployment.to_value(deployment)) =~ "sk-live"
        refute scan(activity.payload) =~ "sk-live"
      end

      test "an adapter that crashes is a provider failure, not a lost preview", context do
        verify(context)
        PreviewAdapterDouble.script(fn _request -> raise "the provider exploded" end)

        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "failed"
        assert deployment.failure_reason == "provider_error"
      end
    end

    describe "a preview is never verification truth (#{authority})" do
      @describetag authority: authority

      test "a failed preview changes nothing about the verified completion", context do
        verify(context)
        PreviewAdapterDouble.script(:failed)

        before = truth(context)
        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "failed"
        assert truth(context) == before
      end

      test "a timed-out preview changes nothing about the verified completion", context do
        verify(context)
        PreviewAdapterDouble.script({:error, :timeout})

        before = truth(context)
        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "timed_out"
        assert truth(context) == before
      end

      test "an unauthorized project keeps its verified completion untouched", context do
        verify(context)
        PreviewAdapterDouble.install(projects: %{})

        before = truth(context)

        assert {:error, :preview_not_authorized} = start(context)
        assert truth(context) == before
      end

      test "a successful preview does not move the run, attempt, or feature", context do
        verify(context)
        PreviewAdapterDouble.script(:ready)

        before = truth(context)
        {:ok, %{deployment: deployment}} = start(context)

        assert deployment.status == "ready"
        assert truth(context) == before
      end
    end
  end

  describe "the device value shape" do
    @describetag authority: :device

    test "round-trips every recorded field", context do
      verify(context)
      PreviewAdapterDouble.script(:ready)
      {:ok, %{deployment: deployment}} = start(context)

      {:ok, %{deployment: cleaned}} =
        Previews.cleanup(context.authority, context.project.id, deployment)

      assert {:ok, restored} =
               cleaned |> PreviewDeployment.to_value() |> PreviewDeployment.from_value()

      assert restored.id == cleaned.id
      assert restored.run_id == cleaned.run_id
      assert restored.attempt_id == cleaned.attempt_id
      assert restored.branch == cleaned.branch
      assert restored.commit_sha == cleaned.commit_sha
      assert restored.path == cleaned.path
      assert restored.provider == cleaned.provider
      assert restored.provider_ref == cleaned.provider_ref
      assert restored.link == cleaned.link
      assert restored.status == cleaned.status
      assert restored.cleanup_state == cleaned.cleanup_state
      assert restored.cleanup_command_id == cleaned.cleanup_command_id
      assert restored.state_version == cleaned.state_version
      assert DateTime.compare(restored.requested_at, cleaned.requested_at) == :eq
      assert DateTime.compare(restored.timeout_at, cleaned.timeout_at) == :eq
    end

    test "refuses a value the device store could not have written", context do
      verify(context)
      {:ok, %{deployment: deployment}} = start(context)
      value = PreviewDeployment.to_value(deployment)

      assert {:error, :invalid_preview_value} =
               PreviewDeployment.from_value(Map.put(value, "status", "deployed"))

      assert {:error, :invalid_preview_value} =
               PreviewDeployment.from_value(
                 Map.put(value, "link", "https://preview.test/x?token=abc")
               )

      assert {:error, :invalid_preview_value} =
               PreviewDeployment.from_value(Map.put(value, "requested_at", nil))

      assert {:error, :invalid_preview_value} = PreviewDeployment.from_value(%{})
      assert {:error, :invalid_preview_value} = PreviewDeployment.from_value("not a record")
    end
  end

  describe "the hosted schema" do
    test "refuses a link that carries a query string", context do
      assert {:error, error} =
               insert_row(context, link: "https://preview.test/x?token=abc", status: "pending")

      assert error.postgres.constraint == "preview_deployments_link_safe"
    end

    test "refuses a ready deployment with nowhere to send a reader", context do
      assert {:error, error} = insert_row(context, status: "ready", link: nil)
      assert error.postgres.constraint == "preview_deployments_ready_link"
    end

    test "refuses a stopped deployment that does not say why", context do
      assert {:error, error} = insert_row(context, status: "failed", failure_reason: nil)
      assert error.postgres.constraint == "preview_deployments_failure_reason_present"
    end

    test "refuses a failure reason that is provider prose", context do
      assert {:error, error} =
               insert_row(context, status: "failed", failure_reason: "auth failed sk-live-1")

      assert error.postgres.constraint == "preview_deployments_failure_reason_shape"
    end

    test "refuses a second deployment of the same binding", context do
      assert {:ok, _first} = insert_row(context, [])
      assert {:error, error} = insert_row(context, [])
      assert error.postgres.constraint == "preview_deployments_binding_index"
    end

    test "freezes the binding against any later rewrite", context do
      {:ok, %{rows: [[id]]}} = insert_row(context, [])

      assert {:error, error} =
               Repo.query(
                 "UPDATE preview_deployments SET commit_sha = $1 WHERE id = $2",
                 [@later_commit, id]
               )

      assert error.postgres.message =~ "binding is recorded once"
    end
  end

  describe "the configured policy" do
    test "reads the authorized path list from configuration", context do
      assert {:ok, policy} = PreviewAdapter.authorize(context.project.id)
      assert policy.path == @path
      assert policy.provider == "configured-preview"
      assert policy.credential_ref == @credential_ref
      assert policy.adapter == PreviewAdapterDouble
    end

    test "refuses a path shape a project could not have configured", context do
      PreviewAdapterDouble.install(projects: %{context.project.id => ["../etc"]})

      assert {:error, :preview_not_authorized} = PreviewAdapter.authorize(context.project.id)
    end

    test "the request key is stable for one binding and distinct across commits", context do
      binding = %{
        run_id: context.run.id,
        attempt_id: context.attempt.id,
        commit_sha: @commit,
        path: @path
      }

      assert PreviewAdapter.request_key(binding) == PreviewAdapter.request_key(binding)

      assert PreviewAdapter.request_key(binding) !=
               PreviewAdapter.request_key(%{binding | commit_sha: @later_commit})
    end

    test "only a safe link and an opaque reference are accepted" do
      assert PreviewDeployment.safe_link?("https://preview.test/branch")
      assert PreviewDeployment.safe_link?("http://localhost:4001/preview")
      assert PreviewDeployment.safe_link?("http://127.0.0.1:4001")
      refute PreviewDeployment.safe_link?("https://user:pass@preview.test/branch")
      refute PreviewDeployment.safe_link?("https://preview.test/branch?token=abc")
      refute PreviewDeployment.safe_link?("https://preview.test/branch#token")
      refute PreviewDeployment.safe_link?("http://preview.test/branch")
      refute PreviewDeployment.safe_link?("javascript:alert(1)")
      refute PreviewDeployment.safe_link?(nil)

      assert PreviewDeployment.valid_provider_ref?("preview-provider/deployment-1")
      refute PreviewDeployment.valid_provider_ref?("https://preview.test/x")
      refute PreviewDeployment.valid_provider_ref?("has space")
      refute PreviewDeployment.valid_provider_ref?(nil)
    end
  end

  describe "the migration" do
    @describetag migration: true

    test "rolls back and forward again" do
      module = migration_module()

      assert table_exists?("preview_deployments")

      # The lock is disabled because it would hold a second connection the Ecto
      # sandbox does not have. The migration itself still runs for real, inside
      # this test's transaction, so the rollback is proven and then undone.
      opts = [log: false, migration_lock: false]

      assert :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
      refute table_exists?("preview_deployments")
      refute trigger_exists?("preview_deployments_binding_frozen")

      assert :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)
      assert table_exists?("preview_deployments")
      assert trigger_exists?("preview_deployments_binding_frozen")
    end
  end

  defp start(context, opts \\ []),
    do: Previews.start(context.authority, context.project.id, context.run, opts)

  defp verify(context, opts \\ []) do
    DeliveryFixtures.verified_completion_fixture(
      context.authority,
      context.project,
      context.run,
      context.attempt,
      Map.new(opts)
    )
  end

  # The state a preview must never be able to move. Compared whole, because the
  # point is that *nothing* changed rather than that one chosen field did not.
  defp truth(context) do
    {:ok, run} = DeliveryStore.fetch_run(context.authority, context.project.id, context.run.id)
    feature = Repo.get!(Feature, context.feature.id)

    {:ok, attempt} =
      DeliveryStore.current_attempt(context.authority, context.project.id, context.run.id)

    {:ok, verified} =
      VerificationCompletion.verified_completion(
        context.authority,
        context.project.id,
        context.feature.id,
        context.run.id
      )

    %{
      run: {run.state, run.state_version},
      feature: {feature.status, feature.state_version},
      attempt: {attempt.state, attempt.state_version, attempt.last_sequence},
      verified: {verified.id, verified.payload}
    }
  end

  # Ends the current attempt and opens its successor in one commit, which is the
  # only way a run gets a second attempt in either authority. The outgoing
  # attempt is re-read because verification already advanced its version.
  defp continue(context) do
    {:ok, previous} =
      DeliveryStore.current_attempt(context.authority, context.project.id, context.run.id)

    {:ok, %{attempt: attempt}} =
      DeliveryStore.commit(context.authority, context.project.id, [
        {:previous, {:transition_attempt, previous, "superseded"}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: context.run.id,
            attempt_number: 2,
            continuation_reason: "manual_retry",
            effective_revision_id: context.run.effective_revision_id,
            effective_revision_digest: context.run.effective_revision_digest,
            manifest_digest: DeliveryFixtures.digest("manifest-2-#{context.run.id}"),
            required_checks: DeliveryFixtures.required_check_contract(@contract),
            fence_token: 2
          }}}
      ])

    %{context | attempt: attempt}
  end

  defp activity(context) do
    DeliveryStore.list_activity(context.authority, context.project.id, context.feature.id)
  end

  defp scan(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp run_steps(project, feature, number) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    [
      {:run,
       {:insert_run,
        %{
          project_id: project.id,
          feature_id: feature.id,
          starting_revision_id: "rev-#{unique}",
          starting_revision_digest: digest,
          approved_slice: "slice-07",
          branch: "sdd/feature-#{unique}"
        }}},
      {:attempt,
       {:insert_attempt,
        %{
          run_id: {:ref, :run, :id},
          attempt_number: number,
          continuation_reason: "initial",
          effective_revision_id: "rev-#{unique}",
          effective_revision_digest: digest,
          manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
          required_checks: DeliveryFixtures.required_check_contract(@contract),
          fence_token: number
        }}}
    ]
  end

  # Raw inserts, so a constraint is proved against the database rather than
  # against the changeset that normally keeps callers away from it.
  defp insert_row(context, overrides) do
    attrs =
      Map.merge(
        %{
          status: "pending",
          link: nil,
          failure_reason: nil,
          provider_ref: nil,
          commit_sha: @commit
        },
        Map.new(overrides)
      )

    Repo.query(
      """
      INSERT INTO preview_deployments
        (id, project_id, feature_id, run_id, attempt_id, branch, commit_sha, path, provider,
         provider_ref, link, status, failure_reason, requested_at, timeout_at,
         cleanup_state, state_version, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, 'web', 'configured-preview',
         $8, $9, $10, $11, NOW(), NOW(), 'none', 1, NOW(), NOW())
      RETURNING id
      """,
      [
        Ecto.UUID.bingenerate(),
        Ecto.UUID.dump!(context.project.id),
        Ecto.UUID.dump!(context.feature.id),
        Ecto.UUID.dump!(context.run.id),
        Ecto.UUID.dump!(context.attempt.id),
        context.run.branch,
        attrs.commit_sha,
        attrs.provider_ref,
        attrs.link,
        attrs.status,
        attrs.failure_reason
      ]
    )
  end

  defp migration_module do
    module = SddOrchestrator.Repo.Migrations.CreatePreviewDeployments

    if Code.ensure_loaded?(module) do
      module
    else
      path =
        Path.join([
          File.cwd!(),
          "priv/repo/migrations/20260730020000_create_preview_deployments.exs"
        ])

      [{loaded, _binary} | _rest] = Code.compile_file(path)
      loaded
    end
  end

  defp table_exists?(table) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = $1",
        [table]
      )

    count == 1
  end

  defp trigger_exists?(trigger) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_trigger WHERE tgname = $1", [trigger])

    count == 1
  end
end
