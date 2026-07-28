defmodule SddOrchestrator.IdentityLinking.MergeRecordTest do
  @moduledoc """
  Proofs for the minimal post-commit merge record: the exact six-field schema and
  the absence of any other field, absorbed-workspace reduction, bounded retention
  and deletion, rights erasure, and restricted access.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts.{Account, Workspace}
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.{IdentityMergeAttempt, WorkspaceMergeRecord}
  alias SddOrchestrator.Privacy.Rights

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures
  import SddOrchestrator.ProjectsFixtures

  defp merged(email \\ "owner@example.com") do
    absorbed = account_fixture()
    absorbed_ws = workspace_fixture(absorbed)
    registered_project(absorbed_ws, name: "Absorbed Alpha")

    %{account: surviving, personal_workspace: surviving_ws} =
      hosted_identity_fixture(email: email)

    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)

    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
    {:ok, confirmed} = IdentityLinking.confirm_merge(proven)
    {:ok, record} = IdentityLinking.commit_merge(confirmed)

    %{
      record: record,
      attempt: confirmed,
      absorbed: absorbed,
      absorbed_ws: absorbed_ws,
      surviving: surviving,
      surviving_ws: surviving_ws
    }
  end

  test "the record table has exactly the six approved fields and nothing else" do
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'workspace_merge_records'"
      )

    columns = rows |> List.flatten() |> Enum.sort()

    assert columns ==
             Enum.sort(
               ~w(merge_event_id source_workspace_id surviving_workspace_id status completed_at delete_after)
             )
  end

  test "commit writes the six-field record and carries no sensitive field" do
    ctx = merged()
    record = ctx.record

    assert record.merge_event_id == ctx.attempt.id
    assert record.source_workspace_id == ctx.absorbed_ws.id
    assert record.surviving_workspace_id == ctx.surviving_ws.id
    assert record.status == "completed"
    assert record.completed_at
    assert record.delete_after

    fields = record |> Map.from_struct() |> Map.drop([:__meta__]) |> Map.keys() |> MapSet.new()

    for forbidden <- [:email, :delivery_email, :project_id, :owner, :name, :account_id, :token] do
      refute MapSet.member?(fields, forbidden)
    end
  end

  test "the deletion deadline is the bounded default (180 days after completion)" do
    ctx = merged()
    assert DateTime.diff(ctx.record.delete_after, ctx.record.completed_at, :day) == 180
  end

  test "the absorbed workspace, account, and transient attempt are reduced to the record only" do
    ctx = merged()

    assert is_nil(Repo.get(Workspace, ctx.absorbed_ws.id))
    assert is_nil(Repo.get(Account, ctx.absorbed.id))
    assert is_nil(Repo.get(IdentityMergeAttempt, ctx.attempt.id))
    # Only the minimal record remains, reachable solely by its merge-event id.
    assert IdentityLinking.get_merge_record(ctx.record.merge_event_id)
  end

  test "get_merge_record is safe for unknown and malformed ids" do
    assert is_nil(IdentityLinking.get_merge_record(Ecto.UUID.generate()))
    assert is_nil(IdentityLinking.get_merge_record("not-a-uuid"))
  end

  test "retention deletes a record past its deadline and keeps a live one" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired =
      %WorkspaceMergeRecord{}
      |> WorkspaceMergeRecord.changeset(%{
        merge_event_id: Ecto.UUID.generate(),
        source_workspace_id: Ecto.UUID.generate(),
        surviving_workspace_id: Ecto.UUID.generate(),
        status: "completed",
        completed_at: DateTime.add(now, -200 * 86_400, :second),
        delete_after: DateTime.add(now, -1, :second)
      })
      |> Repo.insert!()

    live =
      %WorkspaceMergeRecord{}
      |> WorkspaceMergeRecord.changeset(%{
        merge_event_id: Ecto.UUID.generate(),
        source_workspace_id: Ecto.UUID.generate(),
        surviving_workspace_id: Ecto.UUID.generate(),
        status: "completed",
        completed_at: now,
        delete_after: DateTime.add(now, 86_400, :second)
      })
      |> Repo.insert!()

    assert IdentityLinking.prune_merge_records(now) == 1
    assert is_nil(Repo.get(WorkspaceMergeRecord, expired.merge_event_id))
    assert Repo.get(WorkspaceMergeRecord, live.merge_event_id)
  end

  test "rights erasure of the surviving account deletes its merge record" do
    ctx = merged()
    assert IdentityLinking.get_merge_record(ctx.record.merge_event_id)

    assert {:ok, _} = Rights.erase_account(ctx.surviving.id)

    assert is_nil(IdentityLinking.get_merge_record(ctx.record.merge_event_id))
  end
end
