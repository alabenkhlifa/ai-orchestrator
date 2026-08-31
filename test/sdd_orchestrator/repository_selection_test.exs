defmodule SddOrchestrator.RepositorySelectionTest do
  # `async: false`: the double swaps application environment, and the request
  # server is one process shared by the whole node.
  use ExUnit.Case, async: false

  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.SelectionRequest
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestrator.RepositorySelectionTransportDouble, as: TransportDouble

  setup do
    on_exit(TransportDouble.install())

    workspace_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()

    %{
      scope: %{device_workspace_id: workspace_id},
      workspace_id: workspace_id,
      worker_id: worker_id,
      attachment: %{device_workspace_id: workspace_id, worker_id: worker_id}
    }
  end

  test "an answered request delivers one outcome to its requester only", context do
    watch_for_delivery()

    {:ok, request_id} =
      RepositorySelection.request(context.scope, context.worker_id,
        candidates: [%{ref: "project-a", identity: "local-repo:v1:salt:digest"}],
        generate: true
      )

    assert [%SelectionRequest{} = pushed] = TransportDouble.pushed()
    assert pushed.id == request_id
    assert pushed.requester == self()
    assert pushed.device_workspace_id == context.workspace_id
    assert pushed.candidates == [%{ref: "project-a", identity: "local-repo:v1:salt:digest"}]
    assert pushed.generate? == true

    assert :ok =
             RepositorySelection.answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "selected",
               "folder_name" => "orchestrator",
               "matches" => ["project-a"],
               "identity" => "local-repo:v1:fresh:digest"
             })

    assert_receive {:repository_selection, ^request_id, {:selected, %SelectionResult{} = result}}
    assert result.folder_name == "orchestrator"
    assert result.matches == ["project-a"]
    assert result.identity == "local-repo:v1:fresh:digest"

    assert_receive {:bystander, :nothing}, 1_000
    refute_receive {:repository_selection, ^request_id, _outcome}, 50
  end

  test "a second answer to the same request is refused and sends nothing more", context do
    {:ok, request_id} = RepositorySelection.request(context.scope, context.worker_id)

    assert :ok = RepositorySelection.answer(context.attachment, selected(request_id))
    assert_receive {:repository_selection, ^request_id, {:selected, %SelectionResult{}}}

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(request_id))

    refute_receive {:repository_selection, ^request_id, _outcome}, 50
  end

  test "an answer for another request, worker, or workspace is refused", context do
    {:ok, request_id} = RepositorySelection.request(context.scope, context.worker_id)

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(Ecto.UUID.generate()))

    other_worker = %{context.attachment | worker_id: Ecto.UUID.generate()}

    assert {:error, :foreign_answer} =
             RepositorySelection.answer(other_worker, selected(request_id))

    other_workspace = %{context.attachment | device_workspace_id: Ecto.UUID.generate()}

    assert {:error, :foreign_answer} =
             RepositorySelection.answer(other_workspace, selected(request_id))

    refute_receive {:repository_selection, ^request_id, _outcome}, 50

    # Nothing was consumed by the refusals: the real attachment still answers.
    assert :ok = RepositorySelection.answer(context.attachment, selected(request_id))
    assert_receive {:repository_selection, ^request_id, {:selected, %SelectionResult{}}}
  end

  test "a cancelled request and an expired request both ignore a late answer", context do
    {:ok, cancelled_id} = RepositorySelection.request(context.scope, context.worker_id)

    assert :ok = RepositorySelection.cancel(cancelled_id)
    assert_receive {:repository_selection, ^cancelled_id, :cancelled}
    assert cancelled_id in Enum.map(TransportDouble.cancelled(), & &1.id)

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(cancelled_id))

    refute_receive {:repository_selection, ^cancelled_id, _outcome}, 50

    {:ok, expired_id} =
      RepositorySelection.request(context.scope, context.worker_id, timeout_ms: 20)

    assert_receive {:repository_selection, ^expired_id, :timeout}, 1_000
    assert expired_id in Enum.map(TransportDouble.cancelled(), & &1.id)

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(expired_id))

    refute_receive {:repository_selection, ^expired_id, _outcome}, 50
  end

  test "the requester's exit cancels the request and a later answer is refused", context do
    test_process = self()
    scope = context.scope
    worker_id = context.worker_id

    requester =
      spawn(fn ->
        {:ok, request_id} = RepositorySelection.request(scope, worker_id)
        send(test_process, {:requested, request_id})
        Process.sleep(:infinity)
      end)

    assert_receive {:requested, request_id}

    Process.exit(requester, :kill)

    assert wait_until(fn -> request_id in Enum.map(TransportDouble.cancelled(), & &1.id) end)

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(request_id))

    refute_receive {:repository_selection, ^request_id, _outcome}, 50
  end

  test "a refused push returns its reason and stores no request", context do
    TransportDouble.script({:error, :no_worker})

    assert {:error, :no_worker} = RepositorySelection.request(context.scope, context.worker_id)

    assert [%SelectionRequest{id: request_id}] = TransportDouble.pushed()

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(request_id))

    refute_receive {:repository_selection, _request_id, _outcome}, 50
  end

  test "losing the worker's channel process delivers :worker_lost", context do
    worker = TransportDouble.worker()
    {:ok, request_id} = RepositorySelection.request(context.scope, context.worker_id)

    Process.exit(worker, :kill)

    assert_receive {:repository_selection, ^request_id, :worker_lost}, 1_000

    assert {:error, :unknown_request} =
             RepositorySelection.answer(context.attachment, selected(request_id))

    refute_receive {:repository_selection, ^request_id, _outcome}, 50
  end

  test "an answer carrying a path is refused and leaves the request open", context do
    {:ok, request_id} = RepositorySelection.request(context.scope, context.worker_id)

    assert {:error, :invalid_result} =
             RepositorySelection.answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "selected",
               "folder_name" => "orchestrator",
               "path" => "/Users/someone/code/orchestrator"
             })

    refute_receive {:repository_selection, ^request_id, _outcome}, 50

    # Refusing changed nothing, so the worker can still answer properly.
    assert :ok =
             RepositorySelection.answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "cancelled"
             })

    assert_receive {:repository_selection, ^request_id, :cancelled}
  end

  defp selected(request_id) do
    %{"request_id" => request_id, "outcome" => "selected", "folder_name" => "orchestrator"}
  end

  # A process that is not the requester. It reports whether any selection
  # outcome reached it at all.
  defp watch_for_delivery do
    test_process = self()

    spawn(fn ->
      receive do
        {:repository_selection, _id, _outcome} = message ->
          send(test_process, {:bystander, message})
      after
        200 -> send(test_process, {:bystander, :nothing})
      end
    end)
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts <= 0 -> false
      true -> wait_again(check, attempts)
    end
  end

  defp wait_again(check, attempts) do
    Process.sleep(10)
    wait_until(check, attempts - 1)
  end
end
