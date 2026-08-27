defmodule SddOrchestrator.Devices.WorkerInitiatedPairingTest do
  @moduledoc """
  specs/38-worker-initiated-pairing Task 7 proof.

  The two halves meet here: a code the app obtained for itself, bound by an
  owner in the dashboard, then completed by the app without the person going
  back to it. This also proves the data rules that make anonymous issuance
  acceptable — unredeemed attempts are discarded, and no code or credential
  reaches a log.
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Devices.{LocalWorker, Pairing, PairingAttempt, PairingIssuanceThrottle}
  alias SddOrchestrator.Privacy.Retention

  require Logger

  setup do
    PairingIssuanceThrottle.reset()
    on_exit(&PairingIssuanceThrottle.reset/0)
    :ok
  end

  defp long_expired do
    DateTime.utc_now() |> DateTime.add(-2 * 86_400) |> DateTime.truncate(:second)
  end

  defp app_attrs do
    policy = SddOrchestrator.Devices.WorkerDiscovery.compatibility_policy()

    %{
      os_family: policy.os_family,
      os_major: List.last(policy.os_majors),
      protocol_version: List.first(policy.protocol_versions),
      app_version: "0.0.0-test"
    }
  end

  describe "the whole round trip (AC-08)" do
    test "an app-issued code, bound by an owner, brings the worker online" do
      workspace_id = Ecto.UUID.generate()

      # 1. The app asks for a code. It belongs to nobody.
      assert {:ok, %{code: code, attempt: attempt}} = Pairing.issue_unbound_code("app")
      assert is_nil(attempt.device_workspace_id)

      # 2. The app polls to see whether anyone has bound it. Not yet, and that
      #    is an ordinary answer rather than a failure it cannot handle.
      assert {:error, :invalid_or_used} = Pairing.complete_pairing(code, app_attrs())
      assert Repo.aggregate(LocalWorker, :count) == 0

      # 3. The owner pastes it into the dashboard.
      assert :ok = Pairing.bind_pairing(code, workspace_id)

      # 4. The app's next poll succeeds, and it takes its own credential.
      assert {:ok, %{worker: worker, credential: credential}} =
               Pairing.complete_pairing(code, app_attrs())

      assert worker.device_workspace_id == workspace_id
      assert {:ok, authed} = Pairing.authenticate_worker(credential)
      assert authed.id == worker.id

      # 5. The workspace can now discover it, with no further action anywhere.
      {:ok, _seen} = Pairing.mark_seen(worker)
      assert [found] = Pairing.active_workers(workspace_id)
      assert found.id == worker.id
    end

    test "polling before anyone binds never consumes the code" do
      workspace_id = Ecto.UUID.generate()
      {:ok, %{code: code}} = Pairing.issue_unbound_code("app")

      for _poll <- 1..5 do
        assert {:error, :invalid_or_used} = Pairing.complete_pairing(code, app_attrs())
      end

      # The code survived every poll, so a slow owner does not strand the app.
      assert :ok = Pairing.bind_pairing(code, workspace_id)
      assert {:ok, _paired} = Pairing.complete_pairing(code, app_attrs())
    end
  end

  describe "unredeemed codes are discarded (AC-10)" do
    test "an expired attempt nobody redeemed is deleted" do
      {:ok, %{attempt: attempt}} = Pairing.issue_unbound_code("app")

      attempt
      |> Ecto.Changeset.change(expires_at: long_expired())
      |> Repo.update!()

      assert %{unredeemed_pairing_attempts: pruned} = Retention.prune_all(DateTime.utc_now())
      assert pruned >= 1
      refute Repo.get(PairingAttempt, attempt.id)
    end

    test "a live attempt and a completed pairing are both left alone" do
      workspace_id = Ecto.UUID.generate()

      {:ok, %{attempt: live}} = Pairing.issue_unbound_code("app")

      {:ok, %{code: code, attempt: used}} = Pairing.issue_unbound_code("app")
      :ok = Pairing.bind_pairing(code, workspace_id)
      {:ok, _paired} = Pairing.complete_pairing(code, app_attrs())

      used
      |> Ecto.Changeset.change(expires_at: long_expired())
      |> Repo.update!()

      Retention.prune_all(DateTime.utc_now())

      # The live one is still usable, and the completed one still records the
      # pairing that happened.
      assert Repo.get(PairingAttempt, live.id)
      assert Repo.get(PairingAttempt, used.id)
    end

    test "a discarded attempt leaves nothing describing a person or a machine" do
      {:ok, %{attempt: attempt}} = Pairing.issue_unbound_code("app")

      stored = Repo.get!(PairingAttempt, attempt.id)

      # Everything it ever held: a random digest, its salt, and timestamps.
      assert is_nil(stored.device_workspace_id)
      assert is_nil(stored.worker_id)
      assert is_binary(stored.code_digest)
      assert is_binary(stored.code_salt)
    end
  end

  describe "no code or credential reaches a log (AC-11)" do
    test "a whole successful pairing logs neither" do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      workspace_id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          {:ok, %{code: code}} = Pairing.issue_unbound_code("app")
          :ok = Pairing.bind_pairing(code, workspace_id)
          {:ok, %{credential: credential}} = Pairing.complete_pairing(code, app_attrs())
          Process.put(:material, {code, credential})
        end)

      {code, credential} = Process.get(:material)
      [_attempt_id, code_secret] = String.split(code, ".", parts: 2)
      [_worker_id, credential_secret] = String.split(credential, ".", parts: 2)

      for material <- [code, credential, code_secret, credential_secret] do
        refute log =~ material
      end
    end

    test "a failed pairing logs neither" do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          {:ok, %{code: code}} = Pairing.issue_unbound_code("app")
          {:error, :invalid_or_used} = Pairing.complete_pairing(code, app_attrs())
          {:error, :invalid_code} = Pairing.bind_pairing("not-a-code", Ecto.UUID.generate())
          Process.put(:failed_code, code)
        end)

      code = Process.get(:failed_code)
      [_id, secret] = String.split(code, ".", parts: 2)

      refute log =~ code
      refute log =~ secret
    end
  end
end
