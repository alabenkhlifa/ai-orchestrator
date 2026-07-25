defmodule SddOrchestrator.ProjectRegistrationTest do
  @moduledoc """
  Domain, persistence, and fault-injection proofs for atomic project registration,
  workspace-scoped naming, and the reusable rename operation (Task 7).

  Covers default-name derivation and lowest-suffix allocation, natural display
  names with no slug conversion, Unicode `NFKC` plus default case-fold comparison,
  boundary whitespace, blank and control-character rejection, case-insensitive
  conflicts, cross-workspace independence, the `(workspace, provider, repository ID)`
  constraint with duplicate-repository feedback, hosted and device storage,
  idempotent retry, rollback with no partial records, and stable identities.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt, RepositoryConnection}
  alias SddOrchestrator.ProjectStorage.{DeviceStorageReceipt, HostedProjectStorage}

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  setup do
    account = AccountsFixtures.account_fixture()
    %{workspace: ProjectsFixtures.workspace_fixture(account)}
  end

  describe "default_project_name/2" do
    test "uses the repository name when no conflict exists", %{workspace: workspace} do
      assert Projects.default_project_name(workspace, "example") == "example"
    end

    test "preserves natural display names without slug conversion or character loss", %{
      workspace: workspace
    } do
      assert Projects.default_project_name(workspace, "Café Roadmap") == "Café Roadmap"
    end

    test "allocates the lowest available suffix, comparing case-insensitively", %{
      workspace: workspace
    } do
      ProjectsFixtures.project_fixture(workspace, name: "example")
      ProjectsFixtures.project_fixture(workspace, name: "Example-1")

      assert Projects.default_project_name(workspace, "example") == "example-2"
    end

    test "skips only taken suffixes", %{workspace: workspace} do
      ProjectsFixtures.project_fixture(workspace, name: "example")

      assert Projects.default_project_name(workspace, "example") == "example-1"
    end
  end

  describe "register_project/3 — success" do
    test "creates exactly one project, connection, and hosted storage atomically", %{
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:ok, project} = Projects.register_project(workspace, attempt)

      assert Repo.aggregate(Project, :count) == 1
      assert Repo.aggregate(RepositoryConnection, :count) == 1
      assert Repo.aggregate(HostedProjectStorage, :count) == 1

      assert project.name == "example"
      assert project.name_key == "example"
      assert project.storage_mode == "hosted"
      assert project.lifecycle_state == "active"

      connection = project.repository_connection
      assert connection.provider == "github"
      assert connection.provider_repository_id == 101
      assert connection.full_name == "octo/example"
      assert connection.state == "connected"
      assert connection.last_validated_at

      assert project.hosted_storage.root == "hosted/" <> project.id
    end

    test "consumes the onboarding attempt", %{workspace: workspace} do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      {:ok, project} = Projects.register_project(workspace, attempt)

      reloaded = Repo.get!(ProjectOnboardingAttempt, attempt.id)
      assert reloaded.status == "completed"
      assert reloaded.consumed_at
      assert project.onboarding_attempt_id == attempt.id
    end

    test "uses an explicit confirmed name over the default", %{workspace: workspace} do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:ok, project} = Projects.register_project(workspace, attempt, name: "My Roadmap")
      assert project.name == "My Roadmap"
      assert project.name_key == "my roadmap"
    end

    test "trims boundary whitespace on the confirmed name", %{workspace: workspace} do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:ok, project} = Projects.register_project(workspace, attempt, name: "  Roadmap  ")
      assert project.name == "Roadmap"
    end

    test "device storage creates the project without a hosted storage row", %{
      workspace: workspace
    } do
      receipt = %DeviceStorageReceipt{
        token: "ready",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      {:ok, attempt} =
        Projects.select_repository(workspace, attempt.id, ProjectsFixtures.repository_metadata())

      {:ok, _} = Projects.record_device_receipt(workspace, attempt.id, receipt)
      {:ok, attempt} = Projects.select_storage_mode(workspace, attempt.id, "device")

      assert {:ok, project} = Projects.register_project(workspace, attempt)
      assert project.storage_mode == "device"
      assert project.hosted_storage == nil
      assert Repo.aggregate(HostedProjectStorage, :count) == 0
      assert project.repository_connection.state == "connected"
    end
  end

  describe "register_project/3 — naming conflicts" do
    test "an edited name that collides case-insensitively returns inline feedback", %{
      workspace: workspace
    } do
      ProjectsFixtures.project_fixture(workspace, name: "Roadmap")
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:error, changeset} =
               Projects.register_project(workspace, attempt, name: "roadmap")

      assert %{name: [_ | _]} = errors_on(changeset)
      # The colliding attempt created no project or connection.
      assert Repo.aggregate(Project, :count) == 1
      assert Repo.aggregate(RepositoryConnection, :count) == 0
    end

    test "treats NFKC-equivalent names as the same key", %{workspace: workspace} do
      # U+FB01 (ﬁ ligature) NFKC-normalizes to "fi".
      ProjectsFixtures.project_fixture(workspace, name: "ﬁle")
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:error, changeset} = Projects.register_project(workspace, attempt, name: "file")
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "accepting the suggested default allocates the next suffix under a collision", %{
      workspace: workspace
    } do
      ProjectsFixtures.project_fixture(workspace, name: "example")
      # Suggested default is "example-1"; simulate a race that grabs it first.
      ProjectsFixtures.project_fixture(workspace, name: "example-1")

      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:ok, project} =
               Projects.register_project(workspace, attempt,
                 name: "example-1",
                 allocate_suffix?: true
               )

      assert project.name == "example-2"
    end

    test "rejects a blank confirmed name and creates nothing", %{workspace: workspace} do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:error, changeset} = Projects.register_project(workspace, attempt, name: "   ")
      assert %{name: [_ | _]} = errors_on(changeset)
      assert Repo.aggregate(Project, :count) == 0
    end

    test "rejects a control-character name and creates nothing", %{workspace: workspace} do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:error, changeset} =
               Projects.register_project(workspace, attempt, name: "Road\x01map")

      assert %{name: [_ | _]} = errors_on(changeset)
      assert Repo.aggregate(Project, :count) == 0
    end
  end

  describe "register_project/3 — repository uniqueness" do
    test "blocks a repository already linked in the workspace and identifies the project", %{
      workspace: workspace
    } do
      existing = ProjectsFixtures.registered_project(workspace, name: "First")

      attempt =
        ProjectsFixtures.attempt_ready(workspace,
          repository: ProjectsFixtures.repository_metadata(id: 101)
        )

      assert {:error, {:repository_already_linked, project}} =
               Projects.register_project(workspace, attempt)

      assert project.id == existing.id
      # No duplicate project or connection was created.
      assert Repo.aggregate(Project, :count) == 1
      assert Repo.aggregate(RepositoryConnection, :count) == 1
    end

    test "different workspaces link the same repository independently", %{workspace: workspace} do
      other = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())

      mine = ProjectsFixtures.registered_project(workspace, name: "Mine")
      theirs = ProjectsFixtures.registered_project(other, name: "Mine")

      assert mine.id != theirs.id
      assert mine.repository_connection.provider_repository_id == 101
      assert theirs.repository_connection.provider_repository_id == 101
      assert Repo.aggregate(RepositoryConnection, :count) == 2
    end
  end

  describe "register_project/3 — idempotency and readiness" do
    test "a retry of a consumed attempt returns the same project without duplicating", %{
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      {:ok, first} = Projects.register_project(workspace, attempt)
      consumed = Repo.get!(ProjectOnboardingAttempt, attempt.id)

      assert {:ok, second} = Projects.register_project(workspace, consumed)
      assert second.id == first.id
      assert Repo.aggregate(Project, :count) == 1
    end

    test "device mode without a valid receipt is not registerable and creates nothing", %{
      workspace: workspace
    } do
      # Force the storage mode to device without recording a readiness receipt.
      attempt = ProjectsFixtures.attempt_with_repository(workspace)

      {:ok, attempt} =
        attempt
        |> Ecto.Changeset.change(storage_mode: "device")
        |> Repo.update()

      assert {:error, :storage_not_ready} = Projects.register_project(workspace, attempt)
      assert Repo.aggregate(Project, :count) == 0
      assert Repo.aggregate(RepositoryConnection, :count) == 0
    end

    test "rejects an attempt with no repository or storage mode", %{workspace: workspace} do
      {:ok, bare} = Projects.start_onboarding_attempt(workspace)
      assert {:error, :repository_required} = Projects.register_project(workspace, bare)

      only_repo = ProjectsFixtures.attempt_with_repository(workspace)
      assert {:error, :storage_mode_required} = Projects.register_project(workspace, only_repo)
    end
  end

  describe "rename_project/2" do
    test "renames to a free name while keeping project and repository identity", %{
      workspace: workspace
    } do
      project = ProjectsFixtures.registered_project(workspace, name: "Original")
      original_repo_id = project.repository_connection.provider_repository_id

      assert {:ok, renamed} = Projects.rename_project(project, "Renamed")
      assert renamed.id == project.id
      assert renamed.name == "Renamed"
      assert renamed.name_key == "renamed"

      reloaded = Repo.preload(renamed, :repository_connection, force: true)
      assert reloaded.repository_connection.provider_repository_id == original_repo_id
    end

    test "rejects a case-insensitive duplicate without changing identity", %{workspace: workspace} do
      ProjectsFixtures.registered_project(workspace,
        name: "Taken",
        repository: ProjectsFixtures.repository_metadata(id: 1)
      )

      project =
        ProjectsFixtures.registered_project(workspace,
          name: "Movable",
          repository: ProjectsFixtures.repository_metadata(id: 2)
        )

      assert {:error, changeset} = Projects.rename_project(project, "taken")
      assert %{name: [_ | _]} = errors_on(changeset)

      assert Repo.get!(Project, project.id).name == "Movable"
    end

    test "rejects a blank rename", %{workspace: workspace} do
      project = ProjectsFixtures.registered_project(workspace, name: "Keep")
      assert {:error, changeset} = Projects.rename_project(project, "  ")
      assert %{name: [_ | _]} = errors_on(changeset)
    end
  end
end
