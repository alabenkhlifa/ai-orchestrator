defmodule SddOrchestrator.Devices.UnboundPairingAttemptTest do
  @moduledoc """
  specs/38-worker-initiated-pairing Task 1 proof.

  A pairing attempt may now exist before anyone knows which device workspace it
  belongs to, so an app that has never been paired can hold a code. This proves
  the two valid shapes both insert, that the shape which would be a credential
  attached to nobody is refused by the database rather than by convention, and
  that the workspace-scoped path every existing caller uses is untouched.
  """
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias SddOrchestrator.Devices.{Pairing, PairingAttempt}

  @constraint "pairing_attempts_bound_before_use_check"

  defp secret do
    %{
      code_digest: :crypto.strong_rand_bytes(32),
      code_salt: :crypto.strong_rand_bytes(16),
      expires_at: DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
    }
  end

  defp insert_unbound do
    %PairingAttempt{}
    |> PairingAttempt.create_unbound_changeset(secret())
    |> Repo.insert()
  end

  describe "unbound attempts (AC-03)" do
    test "an attempt inserts with no device workspace" do
      assert {:ok, attempt} = insert_unbound()

      assert is_nil(attempt.device_workspace_id)
      assert is_nil(attempt.confirmed_at)
      assert is_nil(attempt.worker_id)
      assert attempt.code_digest
    end

    test "a caller cannot smuggle a workspace in through the attrs" do
      workspace_id = Ecto.UUID.generate()

      assert {:ok, attempt} =
               %PairingAttempt{}
               |> PairingAttempt.create_unbound_changeset(
                 Map.put(secret(), :device_workspace_id, workspace_id)
               )
               |> Repo.insert()

      # The field is not cast, so the attempt is unbound however it was asked for.
      assert is_nil(attempt.device_workspace_id)
    end

    test "an unbound attempt holds nothing describing a person or a machine" do
      assert {:ok, attempt} = insert_unbound()

      stored = Repo.get!(PairingAttempt, attempt.id)

      assert is_nil(stored.device_workspace_id)
      assert is_nil(stored.worker_id)
      # Everything left is a random digest, its salt, and timestamps.
      assert is_binary(stored.code_digest)
      assert is_binary(stored.code_salt)
    end
  end

  describe "the invalid third shape is unreachable" do
    test "the database refuses confirming an attempt that belongs to no workspace" do
      {:ok, attempt} = insert_unbound()

      assert_raise Postgrex.Error, ~r/#{@constraint}/, fn ->
        SQL.query!(
          Repo,
          "UPDATE pairing_attempts SET confirmed_at = NOW() WHERE id = $1",
          [Ecto.UUID.dump!(attempt.id)]
        )
      end
    end

    test "the database refuses attaching a worker to an attempt that belongs to no workspace" do
      {:ok, attempt} = insert_unbound()
      {:ok, %{worker: worker}} = Pairing.start_pairing(Ecto.UUID.generate()) |> complete()

      assert_raise Postgrex.Error, ~r/#{@constraint}/, fn ->
        SQL.query!(
          Repo,
          "UPDATE pairing_attempts SET worker_id = $1 WHERE id = $2",
          [Ecto.UUID.dump!(worker.id), Ecto.UUID.dump!(attempt.id)]
        )
      end
    end

    test "an attempt that carries a workspace may be confirmed" do
      workspace_id = Ecto.UUID.generate()

      {:ok, attempt} =
        %PairingAttempt{}
        |> PairingAttempt.create_changeset(Map.put(secret(), :device_workspace_id, workspace_id))
        |> Repo.insert()

      assert %{num_rows: 1} =
               SQL.query!(
                 Repo,
                 "UPDATE pairing_attempts SET confirmed_at = NOW() WHERE id = $1",
                 [Ecto.UUID.dump!(attempt.id)]
               )
    end
  end

  describe "the workspace-scoped path is unchanged" do
    test "start_pairing still produces a bound attempt and still pairs" do
      workspace_id = Ecto.UUID.generate()

      assert {:ok, %{attempt: attempt, code: code}} = Pairing.start_pairing(workspace_id)
      assert attempt.device_workspace_id == workspace_id

      assert {:ok, %{worker: worker, credential: credential}} = Pairing.complete_pairing(code)
      assert worker.device_workspace_id == workspace_id
      assert {:ok, authed} = Pairing.authenticate_worker(credential)
      assert authed.id == worker.id
    end

    test "create_changeset still requires a workspace" do
      changeset = PairingAttempt.create_changeset(%PairingAttempt{}, secret())

      refute changeset.valid?
      assert %{device_workspace_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  defp complete({:ok, %{code: code}}), do: Pairing.complete_pairing(code)
end
