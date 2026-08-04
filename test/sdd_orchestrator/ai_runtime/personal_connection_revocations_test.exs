defmodule SddOrchestrator.AIRuntime.PersonalConnectionRevocationsTest do
  @moduledoc """
  Task 13 proof for personal-connection cleanup and credential-revocation
  reconciliation.

  Advisory-locked sweeps are session-scoped, so this proof runs serially.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{
    PersonalAIConnection,
    PersonalConnectionAdapter,
    PersonalConnectionRevocations,
    PersonalConnections
  }

  alias SddOrchestrator.AIRuntime.PersonalConnectionAdapter.RPC
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.PersonalConnectionAdapterDouble
  alias SddOrchestrator.Privacy.{Retention, Rights}

  @requested_at ~U[2026-08-04 12:00:00Z]

  @unreachable [
    adapter: PersonalConnectionAdapterDouble,
    revoke_result: {:error, :worker_unavailable}
  ]

  @confirming [adapter: PersonalConnectionAdapterDouble]

  setup do
    %{account: account_fixture(), worker: personal_ai_worker_fixture()}
  end

  describe "immediate denial and worker-local credential removal" do
    test "requesting revocation denies new work even when the worker never answers", context do
      connection = link(context)

      assert {:ok, _reference} =
               PersonalConnections.resolve_support_connection(context.account, connection.id)

      assert {:ok, denied} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @unreachable
               )

      assert denied.revocation_state == "requested"

      assert {:error, :revoking} =
               PersonalConnections.resolve_support_connection(context.account, connection.id)

      assert {:error, :revoking} =
               PersonalConnections.resolve_working_agent_connection(
                 context.account,
                 connection.id
               )
    end

    test "an acknowledged removal makes the connection terminal and schedules its deletion",
         context do
      connection = link(context)

      assert {:ok, acknowledged} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at, notify: self()] ++ @confirming
               )

      assert_received {:adapter_revoke, account, worker, request}
      assert account.id == context.account.id
      assert worker.id == context.worker.id
      assert request == %{worker_profile_ref: connection.worker_profile_ref}

      assert acknowledged.revocation_state == "acknowledged"
      assert acknowledged.revocation_requested_at == @requested_at
      assert acknowledged.revocation_acknowledged_at == @requested_at
      assert acknowledged.credential_removal_result == "removed"
      assert acknowledged.credential_removal_failure_reason == nil
      assert acknowledged.credential_removal_attempts == 1

      assert acknowledged.deletion_scheduled_at ==
               DateTime.add(
                 @requested_at,
                 PersonalConnections.revoked_reference_lifetime_seconds(),
                 :second
               )

      assert {:error, :revoked} =
               PersonalConnections.resolve_support_connection(context.account, connection.id)
    end

    test "a worker that reports no local credential still acknowledges the removal", context do
      connection = link(context)

      assert {:ok, acknowledged} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at, worker_credential_removal: "absent"] ++ @confirming
               )

      assert acknowledged.revocation_state == "acknowledged"
      assert acknowledged.credential_removal_result == "absent"
    end

    test "an unavailable worker leaves the request outstanding with one typed reason", context do
      connection = link(context)

      assert {:ok, pending} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @unreachable
               )

      assert pending.revocation_state == "requested"
      assert pending.credential_removal_result == nil
      assert pending.deletion_scheduled_at == nil
      assert pending.credential_removal_failure_reason == "worker_unavailable"
      assert pending.credential_removal_attempted_at == @requested_at
      assert pending.credential_removal_attempts == 1
    end

    test "a revoked pairing is unreachable rather than a false acknowledgement", context do
      connection = link(context)
      {:ok, _revoked} = Pairing.revoke_worker(context.worker)

      assert {:ok, pending} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @confirming
               )

      assert pending.revocation_state == "requested"
      assert pending.credential_removal_failure_reason == "worker_unavailable"
    end

    test "every adapter failure is normalized to the typed removal vocabulary", context do
      failures = [
        {{:error, :timeout}, "timeout"},
        {{:error, :incompatible}, "incompatible"},
        {{:error, :invalid_request}, "invalid_request"},
        {{:error, :worker_disconnected}, "worker_unavailable"},
        {{:error, {:provider_error, "raw provider text"}}, "invalid_response"},
        {{:ok, %{"worker_profile_ref" => "other", "credential_removal" => "removed"}},
         "invalid_response"},
        {{:ok, %{"credential_removal" => "removed"}}, "invalid_response"},
        {:not_a_result, "invalid_response"}
      ]

      for {{result, expected}, index} <- Enum.with_index(failures) do
        connection = link(context, %{label: "Failure #{index}", profile: "failure-#{index}"})

        assert {:ok, pending} =
                 PersonalConnections.request_revocation(
                   context.account,
                   connection.id,
                   at: @requested_at,
                   adapter: PersonalConnectionAdapterDouble,
                   revoke_result: result
                 )

        assert pending.revocation_state == "requested"
        assert pending.credential_removal_failure_reason == expected
      end
    end

    test "an acknowledgement may not carry credentials, provider identity, or raw errors" do
      request = %{worker_profile_ref: "profile-strict"}
      safe = %{"worker_profile_ref" => "profile-strict", "credential_removal" => "removed"}

      assert {:ok, %{credential_removal: "removed", worker_profile_ref: "profile-strict"}} =
               PersonalConnectionAdapter.validate_revocation_result(safe, request)

      unsafe = [
        Map.put(safe, "credential", "sk-live-secret"),
        Map.put(safe, "api_key", "sk-live-secret"),
        Map.put(safe, "provider_email", "identity@example.test"),
        Map.put(safe, "provider_account_id", "acct-1"),
        Map.put(safe, "provider_workspace_id", "workspace-1"),
        Map.put(safe, "plan_detail", "pro"),
        Map.put(safe, "raw_error", "provider said too much"),
        Map.put(safe, "credential_removal", "maybe"),
        Map.delete(safe, "credential_removal")
      ]

      for result <- unsafe do
        assert {:error, :invalid_response} =
                 PersonalConnectionAdapter.validate_revocation_result(result, request)
      end
    end

    test "the production RPC adapter sends only the connection/1 revoke contract", context do
      request = %{worker_profile_ref: "rpc-profile"}

      assert {:ok, %{credential_removal: "removed"}} =
               RPC.revoke(context.account, context.worker, request,
                 rpc: PersonalConnectionAdapterDouble,
                 rpc_result:
                   {:ok,
                    %{"worker_profile_ref" => "rpc-profile", "credential_removal" => "removed"}},
                 notify: self()
               )

      assert_received {:rpc_request, account_id, workspace_id, worker_id, "connection/1", params}
      assert account_id == context.account.id
      assert workspace_id == context.worker.device_workspace_id
      assert worker_id == context.worker.id
      assert params == %{"operation" => "revoke", "worker_profile_ref" => "rpc-profile"}

      assert {:error, :invalid_response} =
               RPC.revoke(context.account, context.worker, request,
                 rpc: PersonalConnectionAdapterDouble,
                 rpc_result:
                   {:ok,
                    %{
                      "worker_profile_ref" => "rpc-profile",
                      "credential_removal" => "removed",
                      "plan" => "pro"
                    }}
               )

      assert {:error, :invalid_request} =
               RPC.revoke(context.account, context.worker, %{worker_profile_ref: nil}, [])
    end

    test "no credential, provider identity, or raw error survives a failed removal", context do
      connection = link(context)
      secret = "sk-live-must-not-persist"

      logs =
        capture_log(fn ->
          assert {:ok, _pending} =
                   PersonalConnections.request_revocation(
                     context.account,
                     connection.id,
                     at: @requested_at,
                     adapter: PersonalConnectionAdapterDouble,
                     revoke_result:
                       {:error,
                        {:provider_error, secret, "identity@example.test", "plan: pro-max"}}
                   )
        end)

      stored = Repo.get!(PersonalAIConnection, connection.id)
      dump = inspect(stored) <> inspect(Map.from_struct(stored)) <> logs

      for leaked <- [secret, "identity@example.test", "plan: pro-max", "provider_error"] do
        refute dump =~ leaked
      end

      assert stored.credential_removal_failure_reason in PersonalAIConnection.credential_removal_failure_reasons()
    end
  end

  describe "reconciliation, retry, and idempotency" do
    test "an outstanding removal is retried until the worker confirms it", context do
      connection = link(context)

      assert {:ok, pending} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @unreachable
               )

      assert pending.credential_removal_attempts == 1

      retry_at = DateTime.add(@requested_at, 3_600, :second)

      assert {:ok, %{acknowledged: 0, outstanding: 1, outstanding_reasons: [:worker_unavailable]}} =
               PersonalConnectionRevocations.reconcile(retry_at, @unreachable)

      still_pending = Repo.get!(PersonalAIConnection, connection.id)
      assert still_pending.revocation_state == "requested"
      assert still_pending.credential_removal_attempts == 2
      assert still_pending.credential_removal_attempted_at == retry_at

      confirmed_at = DateTime.add(retry_at, 3_600, :second)

      assert {:ok, %{connections: 1, acknowledged: 1, outstanding: 0, outstanding_reasons: []}} =
               PersonalConnectionRevocations.reconcile(confirmed_at, @confirming)

      acknowledged = Repo.get!(PersonalAIConnection, connection.id)
      assert acknowledged.revocation_state == "acknowledged"
      assert acknowledged.revocation_acknowledged_at == confirmed_at
      assert acknowledged.credential_removal_result == "removed"
      assert acknowledged.credential_removal_failure_reason == nil
      assert acknowledged.credential_removal_attempts == 3
    end

    test "reconciliation is idempotent and never re-contacts a terminal connection", context do
      connection = link(context)

      assert {:ok, _acknowledged} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @confirming
               )

      before = Repo.get!(PersonalAIConnection, connection.id)

      for _repeat <- 1..3 do
        assert {:ok, %{connections: 0, acknowledged: 0, outstanding: 0}} =
                 PersonalConnectionRevocations.reconcile(
                   DateTime.add(@requested_at, 60, :second),
                   @confirming ++ [notify: self()]
                 )
      end

      refute_received {:adapter_revoke, _account, _worker, _request}
      assert Repo.get!(PersonalAIConnection, connection.id) == before
    end

    test "a concurrently held sweep lock yields instead of duplicating removals", context do
      connection = link(context)

      assert {:ok, _pending} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @unreachable
               )

      holder = start_lock_holder()

      assert :locked = PersonalConnectionRevocations.reconcile(@requested_at, @confirming)
      assert Repo.get!(PersonalAIConnection, connection.id).revocation_state == "requested"

      release_lock_holder(holder)

      assert {:ok, %{acknowledged: 1}} =
               PersonalConnectionRevocations.reconcile(@requested_at, @confirming)
    end
  end

  describe "terminal deletion schedule" do
    test "retention deletes an acknowledged reference only after its configured lifetime",
         context do
      connection = link(context)

      assert {:ok, acknowledged} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @confirming
               )

      just_before = DateTime.add(acknowledged.deletion_scheduled_at, -1, :second)

      assert %{revoked_personal_ai_connections: 0} = Retention.prune_all(just_before)
      assert Repo.get(PersonalAIConnection, connection.id)

      assert %{revoked_personal_ai_connections: 1} =
               Retention.prune_all(acknowledged.deletion_scheduled_at)

      refute Repo.get(PersonalAIConnection, connection.id)

      assert %{revoked_personal_ai_connections: 0} =
               Retention.prune_all(acknowledged.deletion_scheduled_at)
    end

    test "a pending revocation is retried by retention and is never deleted on a timer",
         context do
      connection = link(context)

      assert {:ok, _pending} =
               PersonalConnections.request_revocation(
                 context.account,
                 connection.id,
                 [at: @requested_at] ++ @unreachable
               )

      far_future = DateTime.add(@requested_at, 365 * 24 * 3_600, :second)

      assert %{
               acknowledged_personal_ai_connections: 0,
               revoked_personal_ai_connections: 0
             } = Retention.prune_all(far_future)

      assert Repo.get!(PersonalAIConnection, connection.id).revocation_state == "requested"
    end
  end

  describe "account erasure and service termination" do
    test "erasure requests worker-local removal and removes the reference anyway", context do
      first = link(context, %{label: "Reachable", profile: "reachable-profile"})
      _second = link(context, %{label: "Offline", profile: "offline-profile"})

      assert {:ok, erasure} =
               Rights.erase_account(
                 context.account.id,
                 [at: @requested_at, notify: self()] ++ @unreachable
               )

      assert erasure.personal_ai_connections == %{
               connections: 2,
               acknowledged: 0,
               outstanding: 2,
               outstanding_reasons: [:worker_unavailable]
             }

      assert_received {:adapter_revoke, _account, _worker, %{worker_profile_ref: _ref}}

      assert Repo.aggregate(PersonalAIConnection, :count) == 0
      refute Repo.get(PersonalAIConnection, first.id)
    end

    test "erasure reports the acknowledged removals it did complete", context do
      link(context)

      assert {:ok, erasure} =
               Rights.erase_account(context.account.id, [at: @requested_at] ++ @confirming)

      assert erasure.personal_ai_connections == %{
               connections: 1,
               acknowledged: 1,
               outstanding: 0,
               outstanding_reasons: []
             }

      assert Repo.aggregate(PersonalAIConnection, :count) == 0
    end

    test "the access export lists connections without the opaque profile reference", context do
      connection = link(context)

      assert {:ok, export} = Rights.export_account(context.account.id)
      assert [exported] = export.personal_ai_connections
      assert exported.id == connection.id
      assert exported.label == "Personal Codex"
      assert exported.revocation_state == "active"
      refute Map.has_key?(exported, :worker_profile_ref)
      refute inspect(export) =~ connection.worker_profile_ref
    end

    test "service termination revokes every connection and is idempotent", context do
      first = link(context, %{label: "First", profile: "first-profile"})
      second = link(context, %{label: "Second", profile: "second-profile"})

      other = account_fixture()

      untouched =
        link(%{context | account: other}, %{label: "Other", profile: "other-profile"})

      assert {:ok, termination} =
               Rights.terminate_personal_ai_service(
                 [at: @requested_at, account: context.account] ++ @confirming
               )

      assert termination.action == :service_termination

      assert termination.personal_ai_connections == %{
               connections: 2,
               acknowledged: 2,
               outstanding: 0,
               outstanding_reasons: []
             }

      for id <- [first.id, second.id] do
        terminal = Repo.get!(PersonalAIConnection, id)
        assert terminal.revocation_state == "acknowledged"
        assert terminal.deletion_scheduled_at
      end

      assert Repo.get!(PersonalAIConnection, untouched.id).revocation_state == "active"

      assert {:ok, repeated} =
               Rights.terminate_personal_ai_service(
                 [at: @requested_at, account: context.account.id] ++ @confirming
               )

      assert repeated.personal_ai_connections == %{
               connections: 0,
               acknowledged: 0,
               outstanding: 0,
               outstanding_reasons: []
             }
    end

    test "unscoped service termination reaches every account and reports outstanding removals",
         context do
      link(context)
      other = account_fixture()
      link(%{context | account: other}, %{label: "Other", profile: "other-profile"})

      assert {:ok, termination} =
               Rights.terminate_personal_ai_service([at: @requested_at] ++ @unreachable)

      assert termination.personal_ai_connections == %{
               connections: 2,
               acknowledged: 0,
               outstanding: 2,
               outstanding_reasons: [:worker_unavailable]
             }

      assert Repo.aggregate(PersonalAIConnection, :count) == 2
    end
  end

  defp link(context, overrides \\ %{}) do
    %{connection: connection} =
      personal_ai_connection_fixture(%{
        account: context.account,
        worker: context.worker,
        label: Map.get(overrides, :label, "Personal Codex"),
        worker_profile_ref: Map.get(overrides, :profile, "profile-primary")
      })

    connection
  end

  # A genuinely separate database session holds the sweep lock, so the contended
  # path is proven against real PostgreSQL rather than a stubbed lock. The
  # sandbox connection cannot serve here: an advisory lock is re-entrant within
  # one session, so a shared connection would grant the lock twice.
  defp start_lock_holder do
    {:ok, holder} = Postgrex.start_link(postgrex_options())
    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: GenServer.stop(holder) end)

    assert %Postgrex.Result{rows: [[:void]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [
               PersonalConnectionRevocations.advisory_lock_key()
             ])

    holder
  end

  defp release_lock_holder(holder) do
    assert %Postgrex.Result{rows: [[true]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [
               PersonalConnectionRevocations.advisory_lock_key()
             ])
  end

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
