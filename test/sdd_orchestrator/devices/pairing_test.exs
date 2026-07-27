defmodule SddOrchestrator.Devices.PairingTest do
  @moduledoc """
  Task 3 proof: secure workspace-bound pairing covering attempt expiry,
  confirmation, replay rejection, revocation, rotation, replacement-worker
  pairing, cross-workspace denial, and non-persistence of raw secrets.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Devices.{LocalWorker, Pairing, PairingAttempt}

  defp workspace_id, do: Ecto.UUID.generate()

  defp pair(workspace \\ workspace_id()) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace)
    {:ok, %{worker: worker, credential: credential}} = Pairing.complete_pairing(code)
    %{workspace: workspace, worker: worker, credential: credential}
  end

  test "confirms a pairing and issues a workspace-bound credential that authenticates" do
    ws = workspace_id()
    {:ok, %{code: code}} = Pairing.start_pairing(ws)

    assert {:ok, %{worker: worker, credential: credential}} = Pairing.complete_pairing(code)
    assert worker.device_workspace_id == ws
    assert worker.state == "active"

    assert {:ok, authed} = Pairing.authenticate_worker(credential)
    assert authed.id == worker.id
  end

  test "rejects a replayed pairing code after it is used once" do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id())
    assert {:ok, _} = Pairing.complete_pairing(code)
    assert {:error, :invalid_or_used} = Pairing.complete_pairing(code)
  end

  test "rejects an expired pairing attempt" do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id(), ttl_seconds: -1)
    assert {:error, :expired} = Pairing.complete_pairing(code)
  end

  test "rejects an invalid or malformed code without leaking existence" do
    assert {:error, :invalid_or_used} = Pairing.complete_pairing("not-a-code")
    assert {:error, :invalid_or_used} = Pairing.complete_pairing("#{Ecto.UUID.generate()}.wrong")
  end

  test "denies a credential presented for a different workspace" do
    %{worker: worker, workspace: ws} = pair()

    assert :ok = Pairing.authorize_for_workspace(worker, ws)
    assert {:error, :cross_workspace} = Pairing.authorize_for_workspace(worker, workspace_id())
  end

  test "revocation stops future authentication without touching other workers" do
    ws = workspace_id()
    %{worker: one, credential: one_cred} = pair(ws)
    %{worker: two, credential: two_cred} = pair(ws)

    assert {:ok, _} = Pairing.revoke_worker(one)

    assert {:error, :unauthorized} = Pairing.authenticate_worker(one_cred)
    assert {:ok, authed} = Pairing.authenticate_worker(two_cred)
    assert authed.id == two.id
  end

  test "rotation invalidates the old credential and accepts the new one" do
    %{worker: worker, credential: old} = pair()

    assert {:ok, %{credential: new}} = Pairing.rotate_credential(worker)
    assert new != old
    assert {:error, :unauthorized} = Pairing.authenticate_worker(old)
    assert {:ok, _} = Pairing.authenticate_worker(new)
  end

  test "cannot rotate a revoked worker" do
    %{worker: worker} = pair()
    {:ok, revoked} = Pairing.revoke_worker(worker)
    assert {:error, :revoked} = Pairing.rotate_credential(revoked)
  end

  test "a replacement worker pairs independently and coexists until the old is revoked" do
    ws = workspace_id()
    %{worker: old, credential: old_cred} = pair(ws)
    %{worker: replacement, credential: replacement_cred} = pair(ws)

    refute replacement.id == old.id
    assert {:ok, _} = Pairing.authenticate_worker(old_cred)
    assert {:ok, _} = Pairing.authenticate_worker(replacement_cred)

    {:ok, _} = Pairing.revoke_worker(old)
    assert {:error, :unauthorized} = Pairing.authenticate_worker(old_cred)
    assert {:ok, _} = Pairing.authenticate_worker(replacement_cred)
  end

  test "persists only digests, never the raw code or credential" do
    ws = workspace_id()
    {:ok, %{attempt: issued, code: code}} = Pairing.start_pairing(ws)
    {:ok, %{worker: worker, credential: credential}} = Pairing.complete_pairing(code)

    attempt = Repo.get(PairingAttempt, issued.id)
    stored = Repo.get(LocalWorker, worker.id)

    [_id, code_secret] = String.split(code, ".", parts: 2)
    [_id, cred_secret] = String.split(credential, ".", parts: 2)

    refute attempt.code_digest == code_secret
    refute stored.credential_digest == cred_secret
    assert is_binary(attempt.code_digest) and byte_size(attempt.code_digest) == 32
    assert is_binary(stored.credential_digest) and byte_size(stored.credential_digest) == 32

    refute inspect(stored) =~ "credential_digest"
    refute inspect(attempt) =~ "code_digest"
  end
end
