defmodule SddOrchestrator.RepositoryScanTest do
  # `async: false`: the double swaps application environment, and the request
  # server is one process shared by the whole node.
  use ExUnit.Case, async: false

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryScan
  alias SddOrchestrator.RepositoryScan.ScanAnswer
  alias SddOrchestrator.RepositoryScan.ScanRequest
  alias SddOrchestrator.RepositoryScanTransportDouble, as: TransportDouble

  @digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit String.duplicate("c", 40)
  @sha256 String.duplicate("d", 64)

  setup do
    on_exit(TransportDouble.install())

    workspace_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()
    command = command()

    request = %{
      project_id: command.project_id,
      device_workspace_id: workspace_id,
      worker_ref: worker_id,
      selection_ref: "selection-ref-1",
      command: command
    }

    %{
      request: request,
      command: command,
      attachment: %{device_workspace_id: workspace_id, worker_id: worker_id}
    }
  end

  test "a scanned answer delivers the evidence to the blocked caller", context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok = RepositoryScan.answer(context.attachment, scanned_answer(request_id))

    assert {:ok, evidence} = Task.await(task)

    assert evidence == %{
             findings: [
               %{
                 category: "check",
                 path: "Makefile",
                 bytes: 12,
                 sha256: @sha256,
                 line_count: 2
               }
             ],
             structure: [%{path: "Makefile", kind: "file"}],
             stats: %{discovered_paths: 4, inspected_files: 1, bytes_read: 12},
             proposal: %{
               commands: ["make test"],
               required_checks: ["make test"],
               allowed_scope: ["."],
               gaps: [],
               conflicts: [],
               multi_root_blockers: []
             }
           }
  end

  test "the request carries the command and the selection, and nothing else", context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    _request_id = wait_for_pushed_id()

    assert [%ScanRequest{} = pushed] = TransportDouble.pushed()
    assert pushed.command == context.command
    assert pushed.selection_ref == "selection-ref-1"
    assert pushed.device_workspace_id == context.attachment.device_workspace_id
    assert pushed.worker_id == context.attachment.worker_id
    assert pushed.project_id == context.command.project_id

    assert :ok = RepositoryScan.answer(context.attachment, scanned_answer(pushed.id))
    assert {:ok, _evidence} = Task.await(task)
  end

  test "a second answer to the same, now-delivered, request is refused and changes nothing",
       context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok = RepositoryScan.answer(context.attachment, scanned_answer(request_id))
    assert {:ok, _evidence} = Task.await(task)

    assert {:error, :unknown_request} =
             RepositoryScan.answer(context.attachment, scanned_answer(request_id))
  end

  test "an answer from a foreign worker or workspace is refused, and the real attachment can still answer",
       context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    request_id = wait_for_pushed_id()

    other_worker = %{context.attachment | worker_id: Ecto.UUID.generate()}

    assert {:error, :foreign_answer} =
             RepositoryScan.answer(other_worker, scanned_answer(request_id))

    other_workspace = %{context.attachment | device_workspace_id: Ecto.UUID.generate()}

    assert {:error, :foreign_answer} =
             RepositoryScan.answer(other_workspace, scanned_answer(request_id))

    assert :ok = RepositoryScan.answer(context.attachment, scanned_answer(request_id))
    assert {:ok, _evidence} = Task.await(task)
  end

  test "every refusal reason reaches the blocked caller by its own name", context do
    for {reason, index} <- Enum.with_index(ScanAnswer.refusal_reasons()) do
      task = Task.async(fn -> RepositoryScan.run(context.request) end)
      request_id = wait_for_pushed_id(index + 1)

      assert :ok =
               RepositoryScan.answer(context.attachment, %{
                 "request_id" => request_id,
                 "outcome" => "refused",
                 "reason" => Atom.to_string(reason)
               })

      assert {:error, ^reason} = Task.await(task)
    end
  end

  test "a malformed answer is refused and leaves the request open to be answered properly",
       context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    request_id = wait_for_pushed_id()

    assert {:error, :invalid_result} =
             RepositoryScan.answer(
               context.attachment,
               Map.put(scanned_answer(request_id), "path", "/Users/someone/code")
             )

    assert :ok = RepositoryScan.answer(context.attachment, scanned_answer(request_id))
    assert {:ok, _evidence} = Task.await(task)
  end

  test "a cancelled outcome resolves the blocked call to :cancelled", context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    request_id = wait_for_pushed_id()

    assert :ok =
             RepositoryScan.answer(context.attachment, %{
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
        RepositoryScan.run(request)
      end)

    assert_receive {:started, ^requester}
    request_id = wait_for_pushed_id()

    Process.exit(requester, :kill)

    assert wait_until(fn -> request_id in Enum.map(TransportDouble.cancelled(), & &1.id) end)

    assert {:error, :unknown_request} =
             RepositoryScan.answer(context.attachment, scanned_answer(request_id))
  end

  test "losing the worker's channel process resolves the blocked call to :worker_unavailable",
       context do
    task = Task.async(fn -> RepositoryScan.run(context.request) end)
    _request_id = wait_for_pushed_id()

    worker = TransportDouble.worker()
    Process.exit(worker, :kill)

    assert {:error, :worker_unavailable} = Task.await(task)
  end

  test "an unanswered request resolves to :worker_unavailable once its wait window closes",
       context do
    task = Task.async(fn -> RepositoryScan.run(context.request, timeout_ms: 10) end)

    assert {:error, :worker_unavailable} = Task.await(task, 1_000)
    assert wait_until(fn -> TransportDouble.cancelled() != [] end)
  end

  test "the default transport refuses at once and leaves nothing open", context do
    TransportDouble.script({:error, :no_worker})

    assert {:error, :worker_unavailable} = RepositoryScan.run(context.request)

    assert [%ScanRequest{id: request_id}] = TransportDouble.pushed()

    assert {:error, :unknown_request} =
             RepositoryScan.answer(context.attachment, scanned_answer(request_id))
  end

  test "the configured default is the transport that refuses without a worker" do
    assert SddOrchestrator.RepositoryScan.Transport.Unavailable.push(%ScanRequest{
             id: "1",
             requester: self(),
             device_workspace_id: Ecto.UUID.generate(),
             project_id: Ecto.UUID.generate(),
             worker_id: Ecto.UUID.generate(),
             selection_ref: "selection-ref-1",
             command: command(),
             expires_at: DateTime.utc_now()
           }) == {:error, :no_worker}
  end

  test "a request missing a field, or holding an invalid command, never touches the transport",
       context do
    assert {:error, :invalid_request} =
             RepositoryScan.run(Map.delete(context.request, :selection_ref))

    assert {:error, :invalid_request} =
             RepositoryScan.run(%{context.request | command: %{}})

    assert {:error, :invalid_request} =
             RepositoryScan.run(%{
               context.request
               | command: %{context.command | limits: %{}}
             })

    assert {:error, :invalid_request} =
             RepositoryScan.run(context.request, timeout_ms: 0)

    assert TransportDouble.pushed() == []
  end

  defp scanned_answer(request_id) do
    %{
      "request_id" => request_id,
      "outcome" => "scanned",
      "findings" => [
        %{
          "category" => "check",
          "path" => "Makefile",
          "bytes" => 12,
          "sha256" => @sha256,
          "line_count" => 2
        }
      ],
      "structure" => [%{"path" => "Makefile", "kind" => "file"}],
      "stats" => %{"discovered_paths" => 4, "inspected_files" => 1, "bytes_read" => 12},
      "proposal" => %{
        "commands" => ["make test"],
        "required_checks" => ["make test"],
        "allowed_scope" => ["."],
        "gaps" => [],
        "conflicts" => [],
        "multi_root_blockers" => []
      }
    }
  end

  defp command do
    assessment =
      struct!(RepositoryAssessment, %{
        id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        repository_provider: "local",
        repository_id: "repository-42",
        root: ".",
        commit: @commit,
        scanner_contract_digest: @digest,
        disclosure_digest: @disclosure_digest,
        worker_ref: Ecto.UUID.generate(),
        state: RepositoryAssessment.pending_state()
      })

    {:ok, command} =
      RepositoryAssessmentCommand.new(assessment, RepositoryAssessmentCommand.default_limits())

    command
  end

  defp wait_for_pushed_id(expected \\ 1) do
    assert wait_until(fn -> length(TransportDouble.pushed()) >= expected end)
    TransportDouble.pushed() |> List.last() |> Map.fetch!(:id)
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
