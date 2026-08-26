defmodule SddOrchestrator.Devices.PairingRedemptionTest do
  @moduledoc """
  specs/38-worker-initiated-pairing Task 2 proof.

  Redemption is the moment an unbound attempt stops being inert. This proves it
  binds and pairs together, that exactly one of two concurrent redemptions wins,
  that a code issued for another workspace cannot be pulled into the redeemer's,
  and that every refusal answers the same thing.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices.{LocalWorker, Pairing, PairingAttempt}

  defp workspace_id, do: Ecto.UUID.generate()

  defp unbound_code(ttl_seconds \\ 600) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    salt = :crypto.strong_rand_bytes(16)
    {:ok, raw} = Base.url_decode64(secret, padding: false)

    {:ok, attempt} =
      %PairingAttempt{}
      |> PairingAttempt.create_unbound_changeset(%{
        code_digest: :crypto.hash(:sha256, salt <> raw),
        code_salt: salt,
        expires_at: DateTime.utc_now() |> DateTime.add(ttl_seconds) |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {attempt, "#{attempt.id}.#{secret}"}
  end

  describe "redeeming an unbound code (AC-04)" do
    test "binds the attempt to the redeemer's workspace and authorizes one worker" do
      ws = workspace_id()
      {attempt, code} = unbound_code()

      assert {:ok, %{worker: worker, credential: credential}} = Pairing.redeem_pairing(code, ws)

      assert worker.device_workspace_id == ws
      assert worker.state == "active"

      bound = Repo.get!(PairingAttempt, attempt.id)
      assert bound.device_workspace_id == ws
      assert bound.worker_id == worker.id
      refute is_nil(bound.confirmed_at)

      assert {:ok, authed} = Pairing.authenticate_worker(credential)
      assert authed.id == worker.id
      assert Repo.aggregate(LocalWorker, :count) == 1
    end

    test "the worker joins the workspace discovery reads" do
      ws = workspace_id()
      {_attempt, code} = unbound_code()

      {:ok, %{worker: worker}} = Pairing.redeem_pairing(code, ws)

      assert [found] = Pairing.active_workers(ws)
      assert found.id == worker.id
    end
  end

  describe "single use and concurrency (AC-05)" do
    test "a second redemption of the same code is refused and authorizes no worker" do
      {_attempt, code} = unbound_code()

      assert {:ok, _} = Pairing.redeem_pairing(code, workspace_id())
      assert {:error, :invalid_code} = Pairing.redeem_pairing(code, workspace_id())

      assert Repo.aggregate(LocalWorker, :count) == 1
    end

    test "exactly one of two concurrent redemptions wins and the loser leaves nothing" do
      {_attempt, code} = unbound_code()
      parent = self()

      tasks =
        for ws <- [workspace_id(), workspace_id()] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Pairing.redeem_pairing(code, ws)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_code})) == 1

      # The loser's worker was rolled back with its transaction.
      assert Repo.aggregate(LocalWorker, :count) == 1
    end
  end

  describe "refusals are indistinguishable (AC-06)" do
    test "expired, canceled, already redeemed, malformed, and unknown answer the same" do
      {_expired_attempt, expired} = unbound_code(-1)

      {canceled_attempt, canceled} = unbound_code()

      canceled_attempt
      |> Ecto.Changeset.change(canceled_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      {_used_attempt, used} = unbound_code()
      {:ok, _} = Pairing.redeem_pairing(used, workspace_id())

      unknown = "#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32))}"

      {_wrong_attempt, wrong_secret_code} = unbound_code()
      [id, _secret] = String.split(wrong_secret_code, ".", parts: 2)
      wrong_secret = "#{id}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"

      answers =
        for code <- [expired, canceled, used, unknown, wrong_secret, "not-a-code", ""] do
          Pairing.redeem_pairing(code, workspace_id())
        end

      assert Enum.uniq(answers) == [{:error, :invalid_code}]
    end

    test "a non-binary code or workspace is refused the same way" do
      {_attempt, code} = unbound_code()

      assert {:error, :invalid_code} = Pairing.redeem_pairing(code, nil)
      assert {:error, :invalid_code} = Pairing.redeem_pairing(nil, workspace_id())
    end
  end

  describe "a code issued for another workspace" do
    test "cannot be pulled into the redeemer's workspace" do
      owner_ws = workspace_id()
      {:ok, %{code: code}} = Pairing.start_pairing(owner_ws)

      assert {:error, :invalid_code} = Pairing.redeem_pairing(code, workspace_id())
      assert Repo.aggregate(LocalWorker, :count) == 0

      # The attempt is untouched, so its rightful owner can still redeem it.
      assert {:ok, %{worker: worker}} = Pairing.redeem_pairing(code, owner_ws)
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
