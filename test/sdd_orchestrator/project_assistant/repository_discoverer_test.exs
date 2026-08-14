defmodule SddOrchestrator.ProjectAssistant.RepositoryDiscovererTest do
  @moduledoc """
  specs/12-project-assistant Task 5 focused proof: bounded progressive
  source discovery and worker-local indexing (AC-13, AC-18) — empty,
  non-SDD, generated-heavy, secret-bearing, and large repository fixtures;
  bounded calls and truncation; invalidation after a source-state change;
  denied cross-project and unauthorized reuse; and no raw source or derived
  index reaching hosted persistence, caches, logs, or backups.
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
  alias SddOrchestrator.ProjectAssistant.RepositoryDiscoverer
  alias SddOrchestrator.ProjectAssistant.RepositoryObserver
  alias SddOrchestrator.ProjectAssistant.RepositorySourceIndex
  alias SddOrchestrator.ProjectsFixtures

  # Fails the test loudly if the discoverer ever calls the adapter after a
  # denied authorization or an unreachable worker.
  defmodule PoisonAdapter do
    @moduledoc false
    @behaviour SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter

    @impl true
    def observe(_request), do: raise("must not run after a denial")

    @impl true
    def tree(_request), do: raise("must not run after a denial")

    @impl true
    def search(_request), do: raise("must not run after a denial")

    @impl true
    def lines(_request), do: raise("must not run after a denial")
  end

  defp always_available, do: fn _authority, _project_id -> true end

  defp hosted_project(repository_ref) do
    owner_account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(owner_account)

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "discoverer-project-#{System.unique_integer([:positive])}",
        workspace_id: workspace.id,
        repository_provider: "test",
        canonical_repository_id: repository_ref
      })
      |> Repo.insert()

    owner_actor = %{account_id: owner_account.id, hosted_identity_id: nil}
    %{workspace: workspace, project: project, owner_actor: owner_actor}
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [adapter: FakeRepositoryObservationAdapter, worker_available: always_available()],
      overrides
    )
  end

  describe "empty and unborn repositories report absence directly" do
    test "an empty repository (no .git at all) reports zero entries and classifies as empty_directory" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("empty")

      assert {:ok, observation} = RepositoryObserver.observe(workspace, project.id, actor, opts())

      assert {:ok, %{entries: []}} =
               RepositoryDiscoverer.tree(workspace, project.id, actor, opts())

      assert RepositoryDiscoverer.classify(observation, %{entries: []}) == :empty_directory
    end

    test "an unborn repository (.git with zero commits) reports zero entries and classifies as unborn_repository" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("unborn")

      assert {:ok, observation} = RepositoryObserver.observe(workspace, project.id, actor, opts())

      assert {:ok, %{entries: []}} =
               RepositoryDiscoverer.tree(workspace, project.id, actor, opts())

      assert RepositoryDiscoverer.classify(observation, %{entries: []}) == :unborn_repository
    end

    test "a mature repository classifies as mature_repository, not an error" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:ok, observation} = RepositoryObserver.observe(workspace, project.id, actor, opts())
      assert {:ok, tree} = RepositoryDiscoverer.tree(workspace, project.id, actor, opts())

      assert RepositoryDiscoverer.classify(observation, tree) == :mature_repository
    end
  end

  describe "a non-SDD repository" do
    test "a search for SDD content returns zero matches, not an error" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("non-sdd")

      assert {:ok, %{matches: [], truncated: false}} =
               RepositoryDiscoverer.search(workspace, project.id, actor, "specs/", opts())
    end
  end

  describe "a generated-heavy repository" do
    test "node_modules and build-output paths are excluded from a tree listing" do
      %{workspace: workspace, project: project, owner_actor: actor} =
        hosted_project("generated-heavy")

      assert {:ok, %{entries: entries}} =
               RepositoryDiscoverer.tree(workspace, project.id, actor, opts())

      paths = Enum.map(entries, & &1.path)
      assert "lib/app.ex" in paths
      refute Enum.any?(paths, &String.contains?(&1, "node_modules"))
      refute Enum.any?(paths, &String.contains?(&1, "_build"))
    end

    test "node_modules matches are excluded from a text search" do
      %{workspace: workspace, project: project, owner_actor: actor} =
        hosted_project("generated-heavy")

      assert {:ok, %{matches: matches}} =
               RepositoryDiscoverer.search(workspace, project.id, actor, "App", opts())

      paths = Enum.map(matches, & &1.path)
      assert "lib/app.ex" in paths
      refute Enum.any?(paths, &String.contains?(&1, "node_modules"))
    end
  end

  describe "a secret-bearing repository" do
    test ".env and secrets/ paths are excluded from a tree listing" do
      %{workspace: workspace, project: project, owner_actor: actor} =
        hosted_project("secret-bearing")

      assert {:ok, %{entries: entries}} =
               RepositoryDiscoverer.tree(workspace, project.id, actor, opts())

      paths = Enum.map(entries, & &1.path)
      assert "lib/app.ex" in paths
      refute ".env" in paths
      refute Enum.any?(paths, &String.contains?(&1, "secrets"))
    end

    test ".env matches are excluded from a text search" do
      %{workspace: workspace, project: project, owner_actor: actor} =
        hosted_project("secret-bearing")

      assert {:ok, %{matches: matches}} =
               RepositoryDiscoverer.search(workspace, project.id, actor, "SECRET_KEY", opts())

      refute Enum.any?(matches, &(&1.path == ".env"))
    end

    test "reading a configured sensitive path directly is denied before the adapter runs" do
      %{workspace: workspace, project: project, owner_actor: actor} =
        hosted_project("secret-bearing")

      assert {:error, :path_denied} =
               RepositoryDiscoverer.lines(
                 workspace,
                 project.id,
                 actor,
                 ".env",
                 1..5,
                 opts(adapter: PoisonAdapter)
               )
    end
  end

  describe "a large repository stays bounded" do
    test "a tree listing is capped at the configured entry limit and reports truncated" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("large")

      assert {:ok, %{entries: entries, truncated: true}} =
               RepositoryDiscoverer.tree(workspace, project.id, actor, opts(max_entries: 20))

      assert length(entries) == 20
    end

    test "a search is capped at the configured result limit and reports truncated" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("large")

      assert {:ok, %{matches: matches, truncated: true}} =
               RepositoryDiscoverer.search(
                 workspace,
                 project.id,
                 actor,
                 "term",
                 opts(max_results: 10)
               )

      assert length(matches) == 10
    end

    test "a line read is truncated to the configured byte budget" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("large")

      assert {:ok, %{content: content, truncated: true}} =
               RepositoryDiscoverer.lines(
                 workspace,
                 project.id,
                 actor,
                 "lib/big.ex",
                 1..10,
                 opts(max_bytes: 500)
               )

      assert byte_size(content) == 500
    end

    test "progressive discovery halts on budget with work remaining rather than a full upload" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("deep")

      assert {:ok, %{halted: :budget_exhausted, entries: entries}} =
               RepositoryDiscoverer.discover(workspace, project.id, actor, opts(max_calls: 1))

      # Only the root listing ran; "src" and its nested content were never requested.
      refute Enum.any?(entries, &String.starts_with?(&1.path, "src/nested"))
    end

    test "progressive discovery completes a small tree well before the call budget" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("deep")

      assert {:ok, %{halted: :complete, entries: entries}} =
               RepositoryDiscoverer.discover(workspace, project.id, actor, opts(max_calls: 10))

      paths = Enum.map(entries, & &1.path)
      assert "src/nested/leaf.ex" in paths
    end
  end

  describe "invalidation and refresh after a source-state change" do
    test "an index built from one observation is not current after the same project's working tree changes" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:ok, before_change} =
               RepositoryObserver.observe(workspace, project.id, actor, opts())

      index = RepositorySourceIndex.build(before_change)
      assert RepositorySourceIndex.current?(index, before_change)

      # Simulate a source change on the same project: the working tree now
      # reports as dirty with uncommitted changes.
      {:ok, _project} =
        project
        |> Project.changeset(%{canonical_repository_id: "dirty"})
        |> Repo.update()

      assert {:ok, after_change} =
               RepositoryObserver.observe(workspace, project.id, actor, opts())

      refute RepositorySourceIndex.current?(index, after_change)
    end

    test "an unstable scan (relevant state changed mid-scan) never yields a reusable current index" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("unstable")

      assert {:ok, unstable_observation} =
               RepositoryObserver.observe(workspace, project.id, actor, opts())

      refute unstable_observation.stable?

      index = RepositorySourceIndex.build(unstable_observation)

      # A fresh observation for the same project a moment later (e.g. after
      # the caller retries) no longer matches the unstable snapshot's key.
      %{workspace: workspace2, project: project2, owner_actor: actor2} = hosted_project("clean")

      refute RepositorySourceIndex.current?(
               index,
               elem(RepositoryObserver.observe(workspace2, project2.id, actor2, opts()), 1)
             )
    end
  end

  describe "denied outcomes never reach the adapter" do
    test "an unauthorized identity is denied on tree without calling the adapter" do
      %{workspace: workspace, project: project} = hosted_project("clean")
      other = ParticipationFixtures.invited_identity_fixture()
      absent_actor = %{account_id: other.account.id, hosted_identity_id: other.hosted_identity.id}

      assert {:error, :unauthorized} =
               RepositoryDiscoverer.tree(
                 workspace,
                 project.id,
                 absent_actor,
                 opts(adapter: PoisonAdapter)
               )
    end

    test "a hosted participant lacking GitHub repository access is denied source_denied on search" do
      owner_account = AccountsFixtures.account_fixture(login: "octo-discoverer")
      workspace = ProjectsFixtures.workspace_fixture(owner_account)
      project = ProjectsFixtures.registered_project(workspace)

      identity = HostedAccessFixtures.hosted_identity_fixture()
      ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      participant_actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      assert {:error, :source_denied} =
               RepositoryDiscoverer.search(
                 workspace,
                 project.id,
                 participant_actor,
                 "term",
                 opts(adapter: PoisonAdapter)
               )
    end

    test "an unreachable worker is denied worker_unavailable on lines without calling the adapter" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("clean")

      assert {:error, :worker_unavailable} =
               RepositoryDiscoverer.lines(
                 workspace,
                 project.id,
                 actor,
                 "lib/app.ex",
                 1..5,
                 adapter: PoisonAdapter,
                 worker_available: fn _authority, _project_id -> false end
               )
    end

    test "a cross-project actor cannot reuse another project's source index" do
      %{workspace: workspace, project: project_a, owner_actor: actor_a} = hosted_project("clean")
      %{project: project_b} = hosted_project("dirty")

      other = ParticipationFixtures.invited_identity_fixture()
      absent_actor = %{account_id: other.account.id, hosted_identity_id: other.hosted_identity.id}

      assert {:ok, observation_a} =
               RepositoryObserver.observe(workspace, project_a.id, actor_a, opts())

      index_a = RepositorySourceIndex.build(observation_a)

      # An index scoped to project A never validates against project B.
      refute RepositorySourceIndex.scope(index_a) ==
               {project_b.id, project_b.repository_provider, project_b.canonical_repository_id}

      # And the absent identity is denied outright, independent of any index.
      assert {:error, :unauthorized} =
               RepositoryDiscoverer.tree(
                 workspace,
                 project_b.id,
                 absent_actor,
                 opts(adapter: PoisonAdapter)
               )
    end
  end

  describe "no hosted persistence, cache, or backup copy of source or index content" do
    test "no migration creates a repository tree, search, line, or source-index table" do
      migration_files =
        [File.cwd!(), "priv", "repo", "migrations", "*.exs"] |> Path.join() |> Path.wildcard()

      forbidden = ~w(repository_tree repository_search repository_line repository_source_index)

      for path <- migration_files,
          content = String.downcase(File.read!(path)),
          needle <- forbidden do
        refute String.contains?(content, needle),
               "#{path} unexpectedly references #{needle}"
      end
    end

    test "no table in the hosted database is named for tree, search, line, or source-index content" do
      %{rows: rows} =
        Repo.query!(
          "select tablename from pg_tables where schemaname = 'public' and (tablename ilike '%repository_tree%' or tablename ilike '%repository_search%' or tablename ilike '%repository_line%' or tablename ilike '%source_index%')"
        )

      assert rows == []
    end

    test "RepositoryDiscoverer exposes no persistence or write function" do
      functions = RepositoryDiscoverer.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
      forbidden = ~w(insert update delete_all commit_delivery cache_tree cache_search put_index)a

      for name <- forbidden do
        refute name in functions, "RepositoryDiscoverer unexpectedly exposes #{name}/N"
      end
    end

    test "the discoverer's own source never calls persistence, cache, or log primitives" do
      source =
        [File.cwd!(), "lib", "sdd_orchestrator", "project_assistant", "repository_discoverer.ex"]
        |> Path.join()
        |> File.read!()

      for needle <- ["Repo.insert", "Repo.update", "commit_delivery", "Logger.", "Cachex"] do
        refute String.contains?(source, needle),
               "repository_discoverer.ex unexpectedly references #{needle}"
      end
    end

    test "running bounded discovery leaves unrelated hosted assistant tables untouched" do
      %{workspace: workspace, project: project, owner_actor: actor} = hosted_project("large")

      before_count =
        Repo.query!("select count(*) from project_context_projections").rows |> List.first()

      assert {:ok, _} = RepositoryDiscoverer.tree(workspace, project.id, actor, opts())
      assert {:ok, _} = RepositoryDiscoverer.search(workspace, project.id, actor, "x", opts())

      after_count =
        Repo.query!("select count(*) from project_context_projections").rows |> List.first()

      assert before_count == after_count
    end
  end

  describe "device authority" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "repository_discoverer_device_#{System.unique_integer([:positive])}/store.dets"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device discoverer project",
          repository_fingerprint:
            "device-discoverer-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      %{workspace: workspace, project: project}
    end

    test "lists the repository tree for the owning device workspace", %{
      workspace: workspace,
      project: project
    } do
      assert {:ok, %{entries: entries}} =
               RepositoryDiscoverer.tree(workspace, project.id, %{}, opts())

      assert Enum.any?(entries, &(&1.path == "README.md"))
    end

    test "denies a mismatched device workspace without calling the adapter", %{project: project} do
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      assert {:error, :unauthorized} =
               RepositoryDiscoverer.tree(
                 other_workspace,
                 project.id,
                 %{},
                 opts(adapter: PoisonAdapter)
               )
    end
  end
end
