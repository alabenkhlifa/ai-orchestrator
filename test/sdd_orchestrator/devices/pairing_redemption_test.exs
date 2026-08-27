defmodule SddOrchestrator.Devices.PairingRedemptionTest do
  @moduledoc """
  specs/38-worker-initiated-pairing Task 2 proof.

  Binding is the moment an unbound attempt stops being inert and becomes
  attached to exactly one owner. It stops there on purpose: only the app knows
  its own versions and only the app should hold its credential, so the app
  finishes afterwards through the endpoint that already exists.

  This proves binding attaches and creates nothing, that exactly one of two
  concurrent bindings wins, that a code issued for another workspace cannot be
  pulled into the redeemer's, that every refusal answers the same thing, and
  that a bound attempt then completes normally.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices.{LocalWorker, Pairing, PairingAttempt}

  defp workspace_id, do: Ecto.UUID.generate()

  defp unbound_code(ttl_seconds \\ 600) do
    {:ok, %{attempt: attempt, code: code}} =
      Pairing.issue_unbound_code("test", ttl_seconds: ttl_seconds)

    {attempt, code}
  end

  defp worker_attrs do
    policy = SddOrchestrator.Devices.WorkerDiscovery.compatibility_policy()

    %{
      os_family: policy.os_family,
      os_major: List.last(policy.os_majors),
      protocol_version: List.first(policy.protocol_versions),
      app_version: "0.0.0-test"
    }
  end

  describe "binding an unbound code (AC-04 domain half)" do
    test "attaches the attempt to the redeemer's workspace and creates no worker" do
      ws = workspace_id()
      {attempt, code} = unbound_code()

      assert :ok = Pairing.bind_pairing(code, ws)

      bound = Repo.get!(PairingAttempt, attempt.id)
      assert bound.device_workspace_id == ws
      # Binding stops here. The worker appears when the app finishes.
      assert is_nil(bound.confirmed_at)
      assert is_nil(bound.worker_id)
      assert Repo.aggregate(LocalWorker, :count) == 0
    end

    test "the app then finishes and receives its own credential" do
      ws = workspace_id()
      {_attempt, code} = unbound_code()

      assert :ok = Pairing.bind_pairing(code, ws)

      # This is the existing endpoint's own path, unchanged, and the app supplies
      # the versions only it knows.
      assert {:ok, %{worker: worker, credential: credential}} =
               Pairing.complete_pairing(code, worker_attrs())

      assert worker.device_workspace_id == ws
      assert worker.os_family == worker_attrs().os_family
      assert {:ok, authed} = Pairing.authenticate_worker(credential)
      assert authed.id == worker.id

      # And only now is it a worker the workspace can discover.
      assert [found] = Pairing.active_workers(ws)
      assert found.id == worker.id
    end
  end

  describe "an unbound attempt cannot be completed" do
    test "completing a code nobody has bound refuses and creates nothing" do
      {_attempt, code} = unbound_code()

      # Refused rather than raised: Task 7 made this an ordinary answer because
      # the app polls completion to learn whether an owner has bound its code
      # yet, and "not yet" must not be a 500. The underlying guards are
      # unchanged — `LocalWorker.create_changeset/2` still requires a workspace
      # and the check constraint still forbids confirming an unbound attempt.
      assert {:error, :invalid_or_used} = Pairing.complete_pairing(code, worker_attrs())

      assert Repo.aggregate(LocalWorker, :count) == 0
    end

    test "the code survives the refusal, so a later binding still works" do
      ws = workspace_id()
      {_attempt, code} = unbound_code()

      assert {:error, :invalid_or_used} = Pairing.complete_pairing(code, worker_attrs())

      assert :ok = Pairing.bind_pairing(code, ws)
      assert {:ok, %{worker: worker}} = Pairing.complete_pairing(code, worker_attrs())
      assert worker.device_workspace_id == ws
    end
  end

  describe "single use and concurrency (AC-05)" do
    test "a second binding of the same code is refused" do
      {_attempt, code} = unbound_code()

      assert :ok = Pairing.bind_pairing(code, workspace_id())
      assert {:error, :invalid_code} = Pairing.bind_pairing(code, workspace_id())
    end

    test "exactly one of two concurrent bindings wins" do
      {attempt, code} = unbound_code()
      parent = self()

      tasks =
        for ws <- [workspace_id(), workspace_id()] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            {ws, Pairing.bind_pairing(code, ws)}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &match?({_ws, :ok}, &1)) == 1
      assert Enum.count(results, &match?({_ws, {:error, :invalid_code}}, &1)) == 1

      # The attempt belongs to the winner alone.
      {winner, :ok} = Enum.find(results, &match?({_ws, :ok}, &1))
      assert Repo.get!(PairingAttempt, attempt.id).device_workspace_id == winner
    end

    test "re-submitting a dashboard-issued code for the same workspace stays harmless" do
      ws = workspace_id()
      {:ok, %{code: code}} = Pairing.start_pairing(ws)

      assert :ok = Pairing.bind_pairing(code, ws)
      assert :ok = Pairing.bind_pairing(code, ws)

      assert {:ok, _paired} = Pairing.complete_pairing(code, worker_attrs())
      assert Repo.aggregate(LocalWorker, :count) == 1
    end
  end

  describe "refusals are indistinguishable (AC-06)" do
    test "expired, canceled, already bound, malformed, and unknown answer the same" do
      {_expired_attempt, expired} = unbound_code(-1)

      {canceled_attempt, canceled} = unbound_code()

      canceled_attempt
      |> Ecto.Changeset.change(canceled_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      {_used_attempt, used} = unbound_code()
      :ok = Pairing.bind_pairing(used, workspace_id())

      unknown = "#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32))}"

      {_wrong_attempt, wrong} = unbound_code()
      [id, _secret] = String.split(wrong, ".", parts: 2)
      wrong_secret = "#{id}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"

      answers =
        for code <- [expired, canceled, used, unknown, wrong_secret, "not-a-code", ""] do
          Pairing.bind_pairing(code, workspace_id())
        end

      assert Enum.uniq(answers) == [{:error, :invalid_code}]
    end

    test "a non-binary code or workspace is refused the same way" do
      {_attempt, code} = unbound_code()

      assert {:error, :invalid_code} = Pairing.bind_pairing(code, nil)
      assert {:error, :invalid_code} = Pairing.bind_pairing(nil, workspace_id())
    end
  end

  describe "a code issued for another workspace" do
    test "cannot be pulled into the redeemer's workspace" do
      owner_ws = workspace_id()
      {:ok, %{code: code}} = Pairing.start_pairing(owner_ws)

      assert {:error, :invalid_code} = Pairing.bind_pairing(code, workspace_id())

      # The attempt is untouched, so its rightful owner can still use it.
      assert :ok = Pairing.bind_pairing(code, owner_ws)
      assert {:ok, %{worker: worker}} = Pairing.complete_pairing(code, worker_attrs())
      assert worker.device_workspace_id == owner_ws
    end
  end

  describe "the existing completion path is unchanged" do
    test "complete_pairing still reports its own specific reasons" do
      {:ok, %{code: expired}} = Pairing.start_pairing(workspace_id(), ttl_seconds: -1)
      assert {:error, :expired} = Pairing.complete_pairing(expired)

      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id())
      assert {:ok, _} = Pairing.complete_pairing(code)
      assert {:error, :invalid_or_used} = Pairing.complete_pairing(code)
    end
  end
end
