defmodule SddOrchestrator.RepositoryMetadataTest do
  # `async: false`: the double swaps application environment, and the request
  # server is one process shared by the whole node.
  use ExUnit.Case, async: false

  alias SddOrchestrator.RepositoryMetadata
  alias SddOrchestrator.RepositoryMetadata.MetadataRequest
  alias SddOrchestrator.RepositoryMetadataTransportDouble, as: TransportDouble

  setup do
    on_exit(TransportDouble.install())

    workspace_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()
    project_id = Ecto.UUID.generate()

    request = %{
      project_id: project_id,
      repository_provider: "github",
      repository_id: "org/repo",
      device_workspace_id: workspace_id,
      worker_ref: worker_id,
      selection_ref: "selection-ref-1",
      selected_root: "selected-root-1",
      scanner_contract_digest: "scanner-digest-1",
      disclosure_digest: "disclosure-digest-1"
    }

    %{
      request: request,
      workspace_id: workspace_id,
      worker_id: worker_id,
      attachment: %{device_workspace_id: workspace_id, worker_id: worker_id}
    }
  end

  test "a successful answer delivers the result to the blocked caller", context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok = RepositoryMetadata.answer(context.attachment, metadata_answer(request_id))

    assert {:ok, result} = Task.await(task)

    assert result == %{
             repository_provider: "github",
             repository_id: "org/repo",
             root: "normalized-root",
             commit: "abc123"
           }
  end

  test "a second answer to the same, now-delivered, request is refused and changes nothing",
       context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok = RepositoryMetadata.answer(context.attachment, metadata_answer(request_id))
    assert {:ok, _result} = Task.await(task)

    assert {:error, :unknown_request} =
             RepositoryMetadata.answer(context.attachment, metadata_answer(request_id))
  end

  test "an answer from a foreign worker or workspace is refused, and the real attachment can still answer",
       context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    request_id = wait_for_pushed_id()

    other_worker = %{context.attachment | worker_id: Ecto.UUID.generate()}

    assert {:error, :foreign_answer} =
             RepositoryMetadata.answer(other_worker, metadata_answer(request_id))

    other_workspace = %{context.attachment | device_workspace_id: Ecto.UUID.generate()}

    assert {:error, :foreign_answer} =
             RepositoryMetadata.answer(other_workspace, metadata_answer(request_id))

    assert :ok = RepositoryMetadata.answer(context.attachment, metadata_answer(request_id))
    assert {:ok, _result} = Task.await(task)
  end

  test "a refused outcome naming repository_mismatch resolves the blocked call to :repository_mismatch",
       context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok =
             RepositoryMetadata.answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "refused",
               "reason" => "repository_mismatch"
             })

    assert {:error, :repository_mismatch} = Task.await(task)
  end

  test "a refused outcome naming a different reason still resolves the blocked call to :invalid_worker_response",
       context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok =
             RepositoryMetadata.answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "refused",
               "reason" => "root_escape"
             })

    assert {:error, :invalid_worker_response} = Task.await(task)
  end

  test "a cancelled outcome resolves the blocked call to :cancelled", context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok =
             RepositoryMetadata.answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "cancelled"
             })

    assert {:error, :cancelled} = Task.await(task)
  end

  test "killing the calling process cleans up the request and tells the transport to cancel",
       context do
    test_process = self()
    request = context.request

    requester =
      spawn(fn ->
        send(test_process, {:started, self()})
        RepositoryMetadata.inspect(request)
      end)

    assert_receive {:started, ^requester}
    request_id = wait_for_pushed_id()

    Process.exit(requester, :kill)

    assert wait_until(fn -> request_id in Enum.map(TransportDouble.cancelled(), & &1.id) end)

    assert {:error, :unknown_request} =
             RepositoryMetadata.answer(context.attachment, metadata_answer(request_id))
  end

  test "losing the worker's channel process resolves the blocked call to :worker_unavailable",
       context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request) end)
    _request_id = wait_for_pushed_id()

    worker = TransportDouble.worker()
    Process.exit(worker, :kill)

    assert {:error, :worker_unavailable} = Task.await(task)
  end

  test "an unanswered request resolves to :worker_unavailable once its timeout expires",
       context do
    task = Task.async(fn -> RepositoryMetadata.inspect(context.request, timeout_ms: 10) end)

    assert {:error, :worker_unavailable} = Task.await(task, 1_000)
  end

  test "a transport push failure resolves at once to :worker_unavailable without tracking a request",
       context do
    TransportDouble.script({:error, :no_worker})

    assert {:error, :worker_unavailable} = RepositoryMetadata.inspect(context.request)

    assert [%MetadataRequest{id: request_id}] = TransportDouble.pushed()

    assert {:error, :unknown_request} =
             RepositoryMetadata.answer(context.attachment, metadata_answer(request_id))
  end

  test "a request missing a required field is refused without touching the transport", context do
    bad_request = Map.delete(context.request, :project_id)

    assert {:error, :invalid_request} = RepositoryMetadata.inspect(bad_request)
    assert TransportDouble.pushed() == []
  end

  defp metadata_answer(request_id) do
    %{
      "request_id" => request_id,
      "outcome" => "metadata",
      "repository_provider" => "github",
      "repository_id" => "org/repo",
      "root" => "normalized-root",
      "commit" => "abc123"
    }
  end

  defp wait_for_pushed_id do
    assert wait_until(fn -> TransportDouble.pushed() != [] end)
    [%MetadataRequest{id: request_id}] = TransportDouble.pushed()
    request_id
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
