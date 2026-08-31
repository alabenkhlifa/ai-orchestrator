defmodule SddOrchestrator.Portability.HostedLocalRepositoryFolderTest do
  @moduledoc """
  Proof for pointing the selected machine at the repository folder (specs/37
  Task 7, reshaped by specs/40 Task 6).

  The owner names the folder and the machine never searches for it. The folder
  is on that machine, so this module asks for it and never opens it: the request
  carries one identity, the answer carries one reference, and no path, remote
  URL, file name, or Git object crosses in either direction.
  """

  # `async: false`: the transport double swaps application environment, and the
  # request server is one process shared by the whole node.
  use ExUnit.Case, async: false

  alias SddOrchestrator.Portability.HostedLocalRepositoryFolder
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.SelectionRequest
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestrator.RepositorySelectionTransportDouble, as: TransportDouble

  @identity "local-repo:v1:c2FsdA:ZGlnZXN0"

  setup do
    on_exit(TransportDouble.install())

    workspace_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()

    %{
      scope: %{device_workspace_id: workspace_id, project_id: Ecto.UUID.generate()},
      workspace_id: workspace_id,
      worker_id: worker_id,
      attachment: %{device_workspace_id: workspace_id, worker_id: worker_id}
    }
  end

  test "the request asks one machine about this project's identity and nothing else", context do
    assert {:ok, request_id} =
             HostedLocalRepositoryFolder.request(context.scope, context.worker_id, @identity)

    assert [%SelectionRequest{} = pushed] = TransportDouble.pushed()
    assert pushed.id == request_id
    assert pushed.requester == self()
    assert pushed.device_workspace_id == context.workspace_id
    assert pushed.project_id == context.scope.project_id
    assert pushed.worker_id == context.worker_id

    # One candidate, under this module's own reference, and no new identity: the
    # project already has one and the only open question is whether the folder
    # is it.
    assert pushed.candidates == [
             %{ref: HostedLocalRepositoryFolder.project_ref(), identity: @identity}
           ]

    assert pushed.generate? == false
  end

  test "a matched answer proves the repository, an unmatched one does not", context do
    {:ok, request_id} =
      HostedLocalRepositoryFolder.request(context.scope, context.worker_id, @identity)

    :ok = RepositorySelection.answer(context.attachment, selected(request_id, ["project"]))

    assert_receive {:repository_selection, ^request_id, {:selected, %SelectionResult{} = result}}

    proof = HostedLocalRepositoryFolder.proof(result, @identity)
    assert is_function(proof, 1)
    assert proof.(@identity) == {:ok, true}

    unmatched = %SelectionResult{request_id: request_id, outcome: :selected, matches: []}
    assert HostedLocalRepositoryFolder.proof(unmatched, @identity).(@identity) == {:ok, false}
  end

  test "a verdict answers only for the identity it was asked about" do
    matched = %SelectionResult{request_id: "r", outcome: :selected, matches: ["project"]}
    proof = HostedLocalRepositoryFolder.proof(matched, @identity)

    # The worker compared the folder against the identity that was sent, so the
    # same verdict means nothing for a project whose identity changed while the
    # panel was open. It is answered false, never connected on a stale true.
    assert proof.(@identity) == {:ok, true}
    assert proof.("local-repo:v1:b3RoZXI:b3RoZXI") == {:ok, false}
    assert proof.("") == {:ok, false}
  end

  test "the reference is recognised in the form a real worker sends it back" do
    result = %SelectionResult{request_id: "r", outcome: :selected, matches: [:project]}
    assert HostedLocalRepositoryFolder.proof(result, @identity).(@identity) == {:ok, true}

    wire = %SelectionResult{request_id: "r", outcome: :selected, matches: ["project"]}
    assert HostedLocalRepositoryFolder.proof(wire, @identity).(@identity) == {:ok, true}

    other = %SelectionResult{request_id: "r", outcome: :selected, matches: ["something-else"]}
    assert HostedLocalRepositoryFolder.proof(other, @identity).(@identity) == {:ok, false}

    unusable = %SelectionResult{request_id: "r", outcome: :selected, matches: [%{"ref" => 1}]}
    assert HostedLocalRepositoryFolder.proof(unusable, @identity).(@identity) == {:ok, false}
  end

  test "no path is asked for, answered with, or held in the proof", context do
    {:ok, request_id} =
      HostedLocalRepositoryFolder.request(context.scope, context.worker_id, @identity)

    [pushed] = TransportDouble.pushed()
    refute inspect(pushed) =~ "/"

    :ok = RepositorySelection.answer(context.attachment, selected(request_id, ["project"]))
    assert_receive {:repository_selection, ^request_id, {:selected, result}}

    # The folder name is the last segment and nothing more, and the proof closes
    # over a verdict and the identity it answers for, and nothing else, so there
    # is nowhere for a path to hide in it.
    assert result.folder_name == "orchestrator"
    proof = HostedLocalRepositoryFolder.proof(result, @identity)
    assert {:env, captured} = :erlang.fun_info(proof, :env)
    assert Enum.sort(captured) == Enum.sort([true, @identity])
    assert proof.(@identity) == {:ok, true}
  end

  test "a refusal never reaches the proof at all", context do
    {:ok, request_id} =
      HostedLocalRepositoryFolder.request(context.scope, context.worker_id, @identity)

    :ok =
      RepositorySelection.answer(context.attachment, %{
        "request_id" => request_id,
        "outcome" => "not_a_git_repository"
      })

    assert_receive {:repository_selection, ^request_id, {:refused, :not_a_git_repository}}
    refute_receive {:repository_selection, ^request_id, {:selected, _result}}, 50
  end

  test "a request that cannot leave the control plane is reported, not left open", context do
    TransportDouble.script({:error, :no_worker})

    assert {:error, :no_worker} =
             HostedLocalRepositoryFolder.request(context.scope, context.worker_id, @identity)

    refute_receive {:repository_selection, _request_id, _outcome}, 50
  end

  defp selected(request_id, matches) do
    %{
      "request_id" => request_id,
      "outcome" => "selected",
      "folder_name" => "orchestrator",
      "matches" => matches
    }
  end
end
