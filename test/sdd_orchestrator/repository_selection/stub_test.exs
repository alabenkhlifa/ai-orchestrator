defmodule SddOrchestrator.RepositorySelection.StubTest do
  @moduledoc """
  Task 6 proof for the development stand-in as a transport.

  The stand-in must answer the way an attached worker answers, not the way a
  test fixture answers: it runs the real Git check and the real identity match
  over the configured folder, and it goes back through the request server so the
  same open-request and single-outcome rules apply. What it skips is the panel
  and the network, never the check.
  """

  # `async: false`: the configured transport and the stub folder are application
  # environment, and the request server is one process shared by the whole node.
  use ExUnit.Case, async: false

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.SelectionRequest
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestrator.RepositorySelection.Stub

  setup do
    assert Application.get_env(:sdd_orchestrator, :repository_selection_transport) == Stub

    root =
      Path.join(System.tmp_dir!(), "sdd_selection_stub_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    repository = init_repo!(Path.join(root, "seeded-repository"))
    {:ok, identity} = PortableRepositoryIdentity.generate(repository)

    workspace_id = Ecto.UUID.generate()

    %{
      root: root,
      repository: repository,
      identity: identity,
      scope: %{device_workspace_id: workspace_id},
      worker_id: Ecto.UUID.generate()
    }
  end

  test "the seeded repository is matched, and the match is computed not scripted", context do
    point_at(context.repository)

    {:ok, request_id} =
      RepositorySelection.request(context.scope, context.worker_id,
        candidates: [%{ref: :project, identity: context.identity}],
        generate: true
      )

    assert_receive {:repository_selection, ^request_id, {:selected, %SelectionResult{} = result}},
                   2_000

    assert result.matches == ["project"]
    assert result.folder_name == "seeded-repository"

    # The identity came back from the folder itself, so it re-matches that same
    # repository and no other.
    assert {:ok, true} = PortableRepositoryIdentity.match(context.repository, result.identity)
  end

  test "an unrelated repository under the same folder is answered as no match", context do
    other = init_repo!(Path.join(context.root, "unrelated"))
    point_at(other)

    {:ok, request_id} =
      RepositorySelection.request(context.scope, context.worker_id,
        candidates: [%{ref: :project, identity: context.identity}]
      )

    assert_receive {:repository_selection, ^request_id, {:selected, result}}, 2_000
    assert result.matches == []
    assert result.identity == nil
  end

  test "a folder that is not a Git repository is refused, not matched", context do
    plain = Path.join(context.root, "plain-folder")
    File.mkdir_p!(plain)
    point_at(plain)

    {:ok, request_id} =
      RepositorySelection.request(context.scope, context.worker_id,
        candidates: [%{ref: :project, identity: context.identity}]
      )

    assert_receive {:repository_selection, ^request_id, {:refused, :not_a_git_repository}}, 2_000
  end

  test "a folder that no longer exists is refused as unreadable", context do
    missing = Path.join(context.root, "gone")
    point_at(missing)

    {:ok, request_id} = RepositorySelection.request(context.scope, context.worker_id)

    assert_receive {:repository_selection, ^request_id, {:refused, :inaccessible}}, 2_000
  end

  test "push answers from another process, so the request server never calls itself", context do
    point_at(context.repository)

    # `push/1` runs inside the request server's own `handle_call`, and `answer/2`
    # is a call to that same server. Answering inline would deadlock, so the
    # answer must come from a process the server can also monitor.
    request = %SelectionRequest{
      id: Ecto.UUID.generate(),
      requester: self(),
      device_workspace_id: context.scope.device_workspace_id,
      worker_id: context.worker_id,
      candidates: [],
      generate?: false,
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    assert {:ok, answering} = Stub.push(request)
    assert is_pid(answering)
    refute answering == self()
    refute answering == Process.whereis(RepositorySelection.Server)

    # And the whole path completes, which it could not if the server were
    # waiting on its own call.
    {:ok, request_id} = RepositorySelection.request(context.scope, context.worker_id)
    assert_receive {:repository_selection, ^request_id, {:selected, _result}}, 2_000
  end

  defp point_at(path) do
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub_folder)
    Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, path)

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, previous)
      else
        Application.delete_env(:sdd_orchestrator, :device_worker_stub_folder)
      end
    end)
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "selection-stub@example.test"])
    git!(path, ["config", "user.name", "Selection Stub"])
    File.write!(Path.join(path, "README.md"), "unchanged #{Path.basename(path)}")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
