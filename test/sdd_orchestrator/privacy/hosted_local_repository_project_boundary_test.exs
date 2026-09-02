defmodule SddOrchestrator.Privacy.HostedLocalRepositoryProjectBoundaryTest do
  @moduledoc """
  `specs/44-hosted-local-repository-projects` Task 4 proof (AC-06): the stored
  records and the logs of a hosted project created from a local repository carry
  no repository path, remote URL, Git history, repository file name, or source
  content, and the project's repository identity is exactly the portable value
  the worker generated.

  The repository is a real Git repository with a real remote, a real commit, and
  real file content, and its identity is generated the way the worker generates
  one (`PortableRepositoryIdentity.generate/1`). The record review is data-driven:
  it reads every row of every table in the database after the creation and asserts
  none of the forbidden values appears anywhere, so a column or a table added
  later is covered without being listed here.

  The folder's own display name is the one repository value the approved design
  lets cross (`specs/05` AC-17: fingerprint plus display name). It names the
  repository rather than locating it, so the repository folder is created under a
  uniquely named parent and every other segment of its path is forbidden.

  The logger level is global, so this case is `async: false`.
  """
  use SddOrchestrator.DataCase, async: false

  require Logger

  import ExUnit.CaptureLog

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.RepositoryValidation
  alias SddOrchestrator.Participation.ProjectMemberProfile
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.{ProjectOnboardingAttempt, RepositoryConnection}
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage

  # Distinctive values planted in the repository. Each one is the kind of detail
  # AC-06 forbids, and each is unusual enough that finding it anywhere is proof it
  # came from this repository.
  @remote_url "https://github.com/private-org-9f2c/hidden-ledger-repo.git"
  @source_file "README.md"
  @source_content "PRIVATE-SOURCE-LINE-3d7b never leaves the Mac"

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    repository = local_repository_fixture()
    on_exit(fn -> File.rm_rf!(repository.root) end)

    device = ProjectsFixtures.device_workspace_fixture()
    hosted = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())

    # The whole creation runs inside the capture, from the identity the worker
    # generates to the committed project, so nothing it logs escapes the review.
    {%{identity: identity, project: project, attempt: attempt, worker: worker}, log} =
      with_log([level: :info], fn ->
        {:ok, identity} = PortableRepositoryIdentity.generate(repository.path)
        worker = ProjectsFixtures.attached_worker_fixture(device)

        attempt =
          ProjectsFixtures.device_attempt_ready_for_hosted(device, hosted,
            repository: %{fingerprint: identity, name: repository.name},
            worker_id: worker.id
          )

        {:ok, project} = Projects.register_project(hosted, attempt, name: "Ledger")

        %{identity: identity, project: project, attempt: attempt, worker: worker}
      end)

    %{
      repository: repository,
      hosted: hosted,
      identity: identity,
      project: project,
      attempt: attempt,
      worker: worker,
      log: log
    }
  end

  describe "the repository identity that is stored" do
    test "is exactly the portable value the worker generated, and still proves the repository",
         %{project: project, identity: identity, repository: repository} do
      assert project.canonical_repository_id == identity
      assert project.repository_provider == "local"
      assert project.storage_mode == "hosted"

      assert {:ok, _portable} = PortableRepositoryIdentity.parse(identity)
      assert {:ok, true} = PortableRepositoryIdentity.match(repository.path, identity)

      # A local repository has no GitHub-shaped connection row to leak a URL from.
      assert Repo.aggregate(RepositoryConnection, :count) == 0
    end

    test "is the only repository value the attempt kept, beside the display name and the worker",
         %{attempt: attempt, identity: identity, repository: repository} do
      stored = Repo.get!(ProjectOnboardingAttempt, attempt.id)

      assert Enum.sort(Map.keys(stored.selected_repository)) ==
               ~w(fingerprint name provider worker_id)

      assert stored.selected_repository["fingerprint"] == identity
      assert stored.selected_repository["name"] == repository.name
      assert stored.selected_repository["provider"] == "local"

      # The attempt is consumed by the creation, not left holding the selection.
      refute is_nil(stored.consumed_at)
    end
  end

  describe "the records the creation wrote" do
    test "are the project, its hosted storage, its worker binding, and the owner profile", %{
      project: project,
      worker: worker,
      hosted: hosted
    } do
      assert Repo.get_by!(HostedProjectStorage, project_id: project.id)

      assert Repo.get_by!(HostedLocalRepositoryBinding, project_id: project.id).worker_id ==
               worker.id

      owner = Repo.get_by!(ProjectMemberProfile, project_id: project.id)
      assert owner.role == "owner"
      assert owner.account_id == hosted.account_id
    end

    test "carry no repository path, remote, history, file name, or source content", %{
      repository: repository,
      identity: identity
    } do
      dump = database_dump()

      # The scan reads real rows: the value that is meant to be there is there.
      assert dump =~ identity

      for forbidden <- forbidden_values(repository) do
        refute dump =~ forbidden,
               "a stored record leaked #{inspect(forbidden)}"
      end
    end
  end

  describe "the logs the creation emitted" do
    test "carry no repository path, remote, history, file name, or source content", %{
      repository: repository,
      log: log
    } do
      for forbidden <- forbidden_values(repository) do
        refute log =~ forbidden, "a log line leaked #{inspect(forbidden)}"
      end
    end

    test "are in fact silent, which is what the scan above found", %{log: log} do
      # Recorded as the finding it is: the whole creation emits nothing at `:info`
      # or above. A future log line on this path fails here and gets reviewed,
      # rather than sliding past an absence scan that can only pass by default.
      assert log == ""
    end

    test "would have been captured: the review's capture is live at :info" do
      captured = capture_log([level: :info], fn -> Logger.info("boundary-capture-probe") end)
      assert captured =~ "boundary-capture-probe"
    end
  end

  # ---- helpers ----

  # Every value that must not survive the boundary: where the repository is, where
  # it came from, what its history is, what is in it, and what it is made of.
  defp forbidden_values(repository) do
    [
      repository.path,
      repository.relative_path,
      Path.basename(repository.root),
      @remote_url,
      "private-org-9f2c",
      "hidden-ledger-repo",
      @source_file,
      @source_content,
      repository.head_sha
    ] ++ repository.root_commit_ids
  end

  # Every row of every table, read as text so a column or a table added later is
  # scanned without being named here. `to_jsonb` renders each row's own columns,
  # whatever their type.
  defp database_dump do
    %{rows: tables} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name
      """)

    Enum.map_join(tables, "\n", fn [table] ->
      %{rows: rows} = Repo.query!("SELECT to_jsonb(t)::text FROM \"#{table}\" t")
      Enum.map_join(rows, "\n", fn [row] -> "#{table} #{row}" end)
    end)
  end

  # A real Git repository with a real remote, commit, and file, under a uniquely
  # named parent directory so its location is distinguishable from its name.
  defp local_repository_fixture do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "sdd_hosted_local_boundary_#{unique}")
    path = Path.join(root, "ledger-#{unique}")
    File.mkdir_p!(path)

    git!(path, ["init", "--quiet"])
    git!(path, ["config", "user.email", "t@example.com"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["remote", "add", "origin", @remote_url])
    File.write!(Path.join(path, @source_file), @source_content)
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "init", "--quiet"])

    {:ok, root_commit_ids} = RepositoryValidation.root_commit_ids(path)

    %{
      root: root,
      path: path,
      relative_path: Path.relative_to(path, System.tmp_dir!()),
      name: Path.basename(path),
      head_sha: git!(path, ["rev-parse", "HEAD"]),
      root_commit_ids: root_commit_ids
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
