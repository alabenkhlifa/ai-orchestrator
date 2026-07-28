defmodule SddOrchestrator.IdentityLinking.WorkerRevocationTest do
  @moduledoc """
  Proofs that a successful merge revokes the absorbed workspace's worker
  credentials inside the same commit — without deleting the worker — while a
  failed merge leaves the prior pairing valid, and the surviving workspace's own
  workers are untouched.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.IdentityLinking

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures
  import SddOrchestrator.ProjectsFixtures

  defp confirmed_merge(email \\ "owner@example.com") do
    absorbed = account_fixture()
    absorbed_ws = workspace_fixture(absorbed)

    %{personal_workspace: surviving_ws} = hosted_identity_fixture(email: email)

    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)

    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
    {:ok, confirmed} = IdentityLinking.confirm_merge(proven)

    %{attempt: confirmed, absorbed_ws: absorbed_ws, surviving_ws: surviving_ws}
  end

  defp active_worker(device_workspace_id) do
    %LocalWorker{}
    |> LocalWorker.create_changeset(%{
      device_workspace_id: device_workspace_id,
      credential_digest: :crypto.hash(:sha256, "secret"),
      credential_salt: :crypto.strong_rand_bytes(16),
      state: "active"
    })
    |> Repo.insert!()
  end

  test "a successful merge revokes the absorbed workspace's worker without deleting it" do
    ctx = confirmed_merge()
    worker = active_worker(ctx.absorbed_ws.id)

    assert {:ok, _committed} = IdentityLinking.commit_merge(ctx.attempt)

    revoked = Repo.get!(LocalWorker, worker.id)
    assert revoked.state == "revoked"
    assert revoked.revoked_at
    # The worker row and its credential material remain; only trust is revoked.
    assert revoked.credential_digest == worker.credential_digest
  end

  test "a worker paired to the surviving workspace is not revoked" do
    ctx = confirmed_merge()
    surviving_worker = active_worker(ctx.surviving_ws.id)

    assert {:ok, _committed} = IdentityLinking.commit_merge(ctx.attempt)

    assert Repo.get!(LocalWorker, surviving_worker.id).state == "active"
  end

  test "a failed merge leaves the absorbed worker's pairing valid" do
    ctx = confirmed_merge()
    worker = active_worker(ctx.absorbed_ws.id)

    # Introduce a conflict after confirmation so the commit rolls back.
    project_fixture(ctx.surviving_ws, name: "Clash")
    project_fixture(ctx.absorbed_ws, name: "clash")

    assert {:error, :conflict} = IdentityLinking.commit_merge(ctx.attempt)

    assert Repo.get!(LocalWorker, worker.id).state == "active"
  end
end
