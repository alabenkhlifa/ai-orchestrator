defmodule SddOrchestratorWeb.WorkerWorkspaceChannelRepositoryScanTest do
  @moduledoc """
  Task 6 proof: a scan request rides the Mac-scoped attachment both ways.

  The properties under test are the ones the metadata request already proves,
  applied to the larger question. A request reaches the worker attached for
  its own workspace and not another worker in it; only that attachment can
  answer it; an answer from another attachment is refused and the request
  stays open for the right one; a worker that did not negotiate the scan
  vocabulary is refused before it is ever asked; and what crosses the wire is
  exactly four keys out, never a stray one back.

  `RepositoryScan.run/2` blocks its caller until exactly one outcome is known,
  so every test that needs to both trigger a push and drive an answer runs it
  inside a `Task.async/1` and awaits it after driving the channel from the
  test process.

  `async: false`: the request server is one named process for the whole node,
  and this file selects the real transport in application environment.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryScan
  alias SddOrchestrator.RepositoryScan.Transport.Attachment
  alias SddOrchestratorWeb.WorkerSocket

  @endpoint SddOrchestratorWeb.Endpoint

  @capability "repository_scan"
  @transport_key :repository_scan_transport
  @digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit String.duplicate("c", 40)
  @sha256 String.duplicate("d", 64)

  setup do
    # `config/test.exs` pins this key to the unavailable stand-in. This file
    # proves the real one, so the choice is made here rather than assumed.
    original = Application.get_env(:sdd_orchestrator, @transport_key)
    Application.put_env(:sdd_orchestrator, @transport_key, Attachment)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:sdd_orchestrator, @transport_key)
        transport -> Application.put_env(:sdd_orchestrator, @transport_key, transport)
      end
    end)

    workspace = Ecto.UUID.generate()
    {:ok, _reply, channel} = attach(workspace)

    %{workspace: workspace, channel: channel, worker_id: DeliveryProtocolFixtures.worker_id()}
  end

  describe "reaching the worker" do
    test "a request is pushed to the worker attached for its workspace", context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryScan.run(attrs) end)

      assert_push "repository_scan", payload
      assert is_binary(payload["request_id"])
      assert payload["selection_ref"] == attrs.selection_ref
      assert payload["command"] == RepositoryAssessmentCommand.to_value(attrs.command)
      assert {:ok, _expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])

      cancel(context.channel, payload["request_id"])
      assert {:error, :cancelled} = Task.await(task)
    end

    test "no worker attached for the asked workspace resolves the blocked call at once",
         context do
      other_workspace = Ecto.UUID.generate()

      assert {:error, :worker_unavailable} =
               RepositoryScan.run(
                 request_attrs(%{workspace: other_workspace, worker_id: context.worker_id})
               )
    end

    test "another worker attached in the same workspace is not asked", context do
      other_worker = DeliveryProtocolFixtures.worker_id()
      {:ok, _reply, _channel} = attach(context.workspace, worker_id: other_worker)

      assert {:error, :worker_unavailable} =
               RepositoryScan.run(
                 request_attrs(%{workspace: context.workspace, worker_id: Ecto.UUID.generate()})
               )
    end

    test "a cancellation reaches the worker as its own push", context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryScan.run(attrs) end)

      assert_push "repository_scan", payload
      request_id = payload["request_id"]

      # A requester's own process exit is the cancellation path; unlink first
      # so killing the task does not also take down this test process.
      Process.unlink(task.pid)
      Process.exit(task.pid, :kill)

      assert_push "repository_scan_cancel", %{"request_id" => ^request_id}
    end
  end

  describe "answering" do
    test "a scanned result from the attachment the request went to resolves the blocked call",
         context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryScan.run(attrs) end)

      assert_push "repository_scan", payload
      ref = push(context.channel, "repository_scan_result", scanned(payload["request_id"]))

      assert_reply ref, :ok, _reply, 2_000

      assert {:ok, evidence} = Task.await(task)
      assert evidence.stats == %{discovered_paths: 4, inspected_files: 1, bytes_read: 12}
      assert evidence.proposal.commands == ["make test"]
    end

    test "a result from another attachment is refused and the blocked call keeps waiting",
         context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryScan.run(attrs) end)

      assert_push "repository_scan", payload
      request_id = payload["request_id"]

      {:ok, _reply, other} = attach(Ecto.UUID.generate())
      foreign_ref = push(other, "repository_scan_result", scanned(request_id))

      assert_reply foreign_ref, :error, %{reason: "foreign_answer"}, 2_000

      # The wrong attachment's answer did not resolve the request: the
      # attachment the request actually went to can still close it.
      real_ref = push(context.channel, "repository_scan_result", scanned(request_id))

      assert_reply real_ref, :ok, _reply, 2_000
      assert {:ok, _evidence} = Task.await(task)
    end

    test "an answer to a request nobody opened is refused", context do
      ref =
        push(context.channel, "repository_scan_result", %{
          "request_id" => Ecto.UUID.generate(),
          "outcome" => "cancelled"
        })

      assert_reply ref, :error, %{reason: "unknown_request"}, 2_000
    end
  end

  describe "capability" do
    test "a worker that did not negotiate repository_scan is refused" do
      workspace = Ecto.UUID.generate()
      announced = List.delete(WorkerProtocol.capabilities(), @capability)

      {:ok, _reply, _channel} = attach(workspace, announcement: %{"capabilities" => announced})

      assert {:error, :worker_unavailable} =
               RepositoryScan.run(
                 request_attrs(%{
                   workspace: workspace,
                   worker_id: DeliveryProtocolFixtures.worker_id()
                 })
               )
    end

    test "the capability is part of the negotiated vocabulary", context do
      assert @capability in WorkerProtocol.capabilities()
      assert Attachment.capability() == @capability

      assert [{_channel, contract}] = WorkerAttachment.attached(context.workspace)
      assert @capability in contract.capabilities
    end
  end

  describe "what crosses the wire" do
    test "the pushed payload holds exactly the four allowed keys and nothing else", context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryScan.run(attrs) end)

      assert_push "repository_scan", payload

      assert Enum.sort(Map.keys(payload)) == [
               "command",
               "expires_at",
               "request_id",
               "selection_ref"
             ]

      cancel(context.channel, payload["request_id"])
      assert {:error, :cancelled} = Task.await(task)
    end

    test "an answer carrying an unrecognized key is refused before it reaches the requester",
         context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryScan.run(attrs) end)

      assert_push "repository_scan", payload
      request_id = payload["request_id"]

      tainted_ref =
        push(
          context.channel,
          "repository_scan_result",
          Map.put(scanned(request_id), "path", "/Users/person/code/orchestrator")
        )

      assert_reply tainted_ref, :error, %{reason: "invalid_result"}, 2_000

      # The refused frame never reached the requester: a clean answer for the
      # same request still resolves the blocked call.
      clean_ref = push(context.channel, "repository_scan_result", scanned(request_id))

      assert_reply clean_ref, :ok, _reply, 2_000
      assert {:ok, _evidence} = Task.await(task)
    end
  end

  defp cancel(channel, request_id) do
    ref =
      push(channel, "repository_scan_result", %{
        "request_id" => request_id,
        "outcome" => "cancelled"
      })

    assert_reply ref, :ok, _reply, 2_000
  end

  defp scanned(request_id) do
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

  defp request_attrs(context) do
    command = command()

    %{
      project_id: command.project_id,
      device_workspace_id: context.workspace,
      worker_ref: context.worker_id,
      selection_ref: Ecto.UUID.generate(),
      command: command
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

  defp attach(device_workspace_id, opts \\ []) do
    worker_id = Keyword.get(opts, :worker_id, DeliveryProtocolFixtures.worker_id())
    token = WorkerSocket.issue({:device_workspace, device_workspace_id}, worker_id)
    {:ok, socket} = connect(WorkerSocket, %{"token" => token})

    subscribe_and_join(
      socket,
      "worker_workspace:#{device_workspace_id}",
      DeliveryProtocolFixtures.announcement(Keyword.get(opts, :announcement, %{}))
    )
  end
end
