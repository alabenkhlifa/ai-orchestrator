defmodule SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter.WorkerTest do
  # `async: false`: the double swaps application environment, and the request
  # server is one process shared by the whole node.
  use ExUnit.Case, async: false

  alias SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter.Worker
  alias SddOrchestrator.RepositoryMetadata.MetadataRequest
  alias SddOrchestrator.RepositoryMetadataTransportDouble, as: TransportDouble

  @commit "0123456789abcdef0123456789abcdef01234567"

  setup do
    request = %{
      project_id: Ecto.UUID.generate(),
      repository_provider: "github",
      repository_id: "org/repo",
      device_workspace_id: Ecto.UUID.generate(),
      worker_ref: Ecto.UUID.generate(),
      selection_ref: "selection-ref-1",
      selected_root: "selected-root-1",
      scanner_contract_digest: "scanner-digest-1",
      disclosure_digest: "disclosure-digest-1"
    }

    %{
      request: request,
      attachment: %{
        device_workspace_id: request.device_workspace_id,
        worker_id: request.worker_ref
      }
    }
  end

  test "prepare/1 returns the worker's result when it answers with metadata", context do
    on_exit(TransportDouble.install())

    task = Task.async(fn -> Worker.prepare(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok = answer(context.attachment, metadata_answer(request_id))

    assert {:ok, result} = Task.await(task)

    assert result == %{
             repository_provider: "github",
             repository_id: "org/repo",
             root: "normalized-root",
             commit: @commit
           }
  end

  test "revalidate/1 behaves identically to prepare/1 given the same request and answer",
       context do
    on_exit(TransportDouble.install())

    task = Task.async(fn -> Worker.revalidate(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok = answer(context.attachment, metadata_answer(request_id))

    assert {:ok, result} = Task.await(task)

    assert result == %{
             repository_provider: "github",
             repository_id: "org/repo",
             root: "normalized-root",
             commit: @commit
           }
  end

  test "a worker's repository_mismatch refusal resolves prepare/1 to :repository_mismatch",
       context do
    on_exit(TransportDouble.install())

    task = Task.async(fn -> Worker.prepare(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok =
             answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "refused",
               "reason" => "repository_mismatch"
             })

    assert {:error, :repository_mismatch} = Task.await(task)
  end

  test "no worker attached resolves prepare/1 to :worker_unavailable", context do
    # No double is installed, so the configured transport is the default
    # `Unavailable` stand-in and the push is refused at once.
    assert {:error, :worker_unavailable} = Worker.prepare(context.request)
  end

  test "a cancelled answer resolves prepare/1 to :worker_unavailable, not :cancelled",
       context do
    on_exit(TransportDouble.install())

    task = Task.async(fn -> Worker.prepare(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok =
             answer(context.attachment, %{
               "request_id" => request_id,
               "outcome" => "cancelled"
             })

    assert {:error, :worker_unavailable} = Task.await(task)
  end

  defp answer(attachment, attrs),
    do: SddOrchestrator.RepositoryMetadata.answer(attachment, attrs)

  defp metadata_answer(request_id) do
    %{
      "request_id" => request_id,
      "outcome" => "metadata",
      "repository_provider" => "github",
      "repository_id" => "org/repo",
      "root" => "normalized-root",
      "commit" => @commit
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
