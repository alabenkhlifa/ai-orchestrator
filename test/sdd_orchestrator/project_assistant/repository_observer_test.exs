defmodule SddOrchestrator.ProjectAssistant.RepositoryObserverTest do
  @moduledoc """
  specs/12-project-assistant Task 4 focused proof: the bounded "observe
  current state" orchestration (AC-08, AC-09, AC-16) — clean, dirty, unborn
  branch, and concurrently changing working-tree fixtures; unauthorized,
  cross-project, source-denied, and worker-offline outcomes; and proof that a
  denied authorization or an unreachable worker never reaches the adapter.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectAssistant.FakeRepositoryObservationAdapter
  alias SddOrchestrator.ProjectAssistant.RepositoryObserver
  alias SddOrchestrator.ProjectsFixtures

  # Fails the test loudly if the orchestrator ever calls the adapter after a
  # denied authorization or an unreachable worker — those checks must
  # short-circuit before this bounded read tool ever runs.
  defmodule PoisonAdapter do
    @moduledoc false
    @behaviour SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter

    @impl true
    def observe(_request),
      do: raise("RepositoryObservationAdapter.observe/1 must not run after a denial")
  end

  defp always_available, do: fn _authority, _project_id -> true end

  defp hosted_project(repository_ref) do
    owner_account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(owner_account)

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "observer-project-#{System.unique_integer([:positive])}",
        workspace_id: workspace.id,
        repository_provider: "test",
        canonical_repository_id: repository_ref
      })
      |> Repo.insert()

    owner_actor = %{account_id: owner_account.id, hosted_identity_id: nil}
    %{workspace: workspace, project: project, owner_actor: owner_actor}
  end

  defp observe(workspace, project_id, actor, opts \\ []) do
    RepositoryObserver.observe(
      workspace,
      project_id,
      actor,
      Keyword.merge(
        [adapter: FakeRepositoryObservationAdapter, worker_available: always_available()],
        opts
      )
    )
  end

  describe "observed working-tree content" do
    test "a clean tree is stable and not dirty" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:ok, observation} = observe(workspace, project.id, actor)

      assert observation.branch == "main"
      assert observation.commit == "abc123def456"
      assert observation.dirty == false
      assert observation.stable? == true
      assert observation.before_digest == observation.after_digest
      assert observation.project_id == project.id
      assert observation.actor_ref == actor.account_id
    end

    test "a dirty tree with uncommitted changes is reported and still stable" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("dirty")

      assert {:ok, observation} = observe(workspace, project.id, actor)

      assert observation.dirty == true
      assert observation.stable? == true
    end

    test "an unborn branch (no commits yet) reports no commit" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("unborn")

      assert {:ok, observation} = observe(workspace, project.id, actor)

      assert observation.commit == nil
      assert observation.branch == "main"
    end

    test "concurrent change during the scan marks the observation unstable" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("unstable")

      assert {:ok, observation} = observe(workspace, project.id, actor)

      assert observation.stable? == false
      refute observation.before_digest == observation.after_digest
    end

    test "exclusions pass through to the observation" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:ok, observation} =
               observe(workspace, project.id, actor, exclusions: ["node_modules/", ".env"])

      assert observation.exclusions == ["node_modules/", ".env"]
    end
  end

  describe "denied outcomes never reach the adapter" do
    test "an unauthorized (cross-project) identity is denied without calling the adapter" do
      %{workspace: workspace, project: project} = hosted_project("clean")
      other = ParticipationFixtures.invited_identity_fixture()
      absent_actor = %{account_id: other.account.id, hosted_identity_id: other.hosted_identity.id}

      assert {:error, :unauthorized} =
               RepositoryObserver.observe(workspace, project.id, absent_actor,
                 adapter: PoisonAdapter,
                 worker_available: always_available()
               )
    end

    test "a hosted participant lacking GitHub repository access is denied as source_denied" do
      owner_account = AccountsFixtures.account_fixture(login: "octo")
      workspace = ProjectsFixtures.workspace_fixture(owner_account)
      project = ProjectsFixtures.registered_project(workspace)

      identity = HostedAccessFixtures.hosted_identity_fixture()
      ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      participant_actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      assert {:error, :source_denied} =
               RepositoryObserver.observe(workspace, project.id, participant_actor,
                 adapter: PoisonAdapter,
                 worker_available: always_available()
               )
    end

    test "an unreachable worker is denied as worker_unavailable without calling the adapter" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:error, :worker_unavailable} =
               RepositoryObserver.observe(workspace, project.id, actor,
                 adapter: PoisonAdapter,
                 worker_available: fn _authority, _project_id -> false end
               )
    end

    test "the real worker-availability check denies by default with no bound worker (genuine offline fixture)" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:error, :worker_unavailable} =
               RepositoryObserver.observe(workspace, project.id, actor,
                 adapter: FakeRepositoryObservationAdapter
               )
    end
  end

  describe "adapter failure passthrough" do
    test "an adapter failure surfaces as its own error without being reinterpreted" do
      %{workspace: workspace, project: project, owner_actor: actor} =
        hosted_project("fails:transport_error")

      assert {:error, :transport_error} = observe(workspace, project.id, actor)
    end
  end

  describe "device authority" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "repository_observer_device_#{System.unique_integer([:positive])}/store.dets"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device observer project",
          repository_fingerprint:
            "device-observer-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      %{workspace: workspace, project: project}
    end

    test "observes the current working tree for the owning device workspace", %{
      workspace: workspace,
      project: project
    } do
      assert {:ok, observation} = observe(workspace, project.id, %{})

      assert observation.dirty == false
      assert observation.actor_ref == workspace.id
    end

    test "denies a mismatched device workspace without calling the adapter", %{project: project} do
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      assert {:error, :unauthorized} =
               RepositoryObserver.observe(other_workspace, project.id, %{},
                 adapter: PoisonAdapter,
                 worker_available: always_available()
               )
    end
  end
end
