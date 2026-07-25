defmodule SddOrchestrator.ProjectsTest do
  @moduledoc """
  Domain and persistence proofs for the Projects context: the workspace-scoped
  catalog read model and the onboarding-attempt lifecycle (initial state,
  idempotency key, active reuse, and workspace-scoped lookup).
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.ProjectOnboardingAttempt

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  setup do
    account = AccountsFixtures.account_fixture()
    %{account: account, workspace: ProjectsFixtures.workspace_fixture(account)}
  end

  describe "catalog" do
    test "an empty workspace has no projects", %{workspace: workspace} do
      refute Projects.has_projects?(workspace)
      assert Projects.list_catalog(workspace) == []
    end

    test "lists a workspace's projects by display name", %{workspace: workspace} do
      ProjectsFixtures.project_fixture(workspace, name: "Beta")
      ProjectsFixtures.project_fixture(workspace, name: "Alpha")

      assert Projects.has_projects?(workspace)
      assert Enum.map(Projects.list_catalog(workspace), & &1.name) == ["Alpha", "Beta"]
    end

    test "the catalog is isolated to its workspace", %{workspace: workspace} do
      other = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      ProjectsFixtures.project_fixture(other, name: "Not Mine")
      ProjectsFixtures.project_fixture(workspace, name: "Mine")

      assert Enum.map(Projects.list_catalog(workspace), & &1.name) == ["Mine"]

      refute Projects.has_projects?(
               ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
             )
    end
  end

  describe "start_onboarding_attempt/1" do
    test "creates an attempt with initial state, an idempotency key, and an expiry", %{
      workspace: workspace
    } do
      assert {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      assert attempt.workspace_id == workspace.id
      assert attempt.status == "started"
      assert is_binary(attempt.idempotency_key) and byte_size(attempt.idempotency_key) > 0
      assert is_nil(attempt.consumed_at)
      # Selected repository / storage are filled by later steps, not at creation.
      assert is_nil(attempt.selected_repository)
      assert is_nil(attempt.storage_mode)
      assert DateTime.compare(attempt.expires_at, DateTime.utc_now()) == :gt
    end

    test "each attempt gets a distinct idempotency key", %{workspace: workspace} do
      {:ok, one} = Projects.start_onboarding_attempt(workspace)
      {:ok, two} = Projects.start_onboarding_attempt(workspace)

      refute one.idempotency_key == two.idempotency_key
    end
  end

  describe "get_or_start_onboarding_attempt/1" do
    test "reuses the workspace's active attempt", %{workspace: workspace} do
      {:ok, started} = Projects.get_or_start_onboarding_attempt(workspace)
      {:ok, reused} = Projects.get_or_start_onboarding_attempt(workspace)

      assert started.id == reused.id
      assert Repo.aggregate(ProjectOnboardingAttempt, :count) == 1
    end

    test "starts a fresh attempt once the active one is consumed", %{workspace: workspace} do
      {:ok, first} = Projects.get_or_start_onboarding_attempt(workspace)

      first
      |> Ecto.Changeset.change(consumed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      {:ok, second} = Projects.get_or_start_onboarding_attempt(workspace)
      refute second.id == first.id
    end

    test "does not reuse an expired attempt", %{workspace: workspace} do
      {:ok, first} = Projects.get_or_start_onboarding_attempt(workspace)

      first
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      {:ok, second} = Projects.get_or_start_onboarding_attempt(workspace)
      refute second.id == first.id
    end
  end

  describe "get_onboarding_attempt/2" do
    test "returns the attempt scoped to its workspace", %{workspace: workspace} do
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
      assert Projects.get_onboarding_attempt(workspace, attempt.id).id == attempt.id
    end

    test "never resolves another workspace's attempt", %{workspace: workspace} do
      other = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      {:ok, foreign} = Projects.start_onboarding_attempt(other)

      assert Projects.get_onboarding_attempt(workspace, foreign.id) == nil
    end

    test "returns nil for a malformed id", %{workspace: workspace} do
      assert Projects.get_onboarding_attempt(workspace, "not-a-uuid") == nil
    end
  end
end
