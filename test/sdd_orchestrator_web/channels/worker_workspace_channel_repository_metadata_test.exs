defmodule SddOrchestratorWeb.WorkerWorkspaceChannelRepositoryMetadataTest do
  @moduledoc """
  Task 3 proof: a metadata request rides the Mac-scoped attachment both ways.

  The properties under test mirror the ones the folder-picker request already
  proves. A request reaches the worker attached for its own workspace; only
  that attachment can answer it; an answer from another attachment is refused
  and the request stays open for the right one; a worker that did not
  negotiate the metadata vocabulary is refused before it is ever asked; and
  what crosses the wire is exactly six keys each way, never a stray one.

  Unlike `RepositorySelection.request/3`, `RepositoryMetadata.inspect/2`
  blocks its caller until exactly one outcome is known, so every test that
  needs to both trigger a push and drive an answer runs `inspect/2` inside a
  `Task.async/1` and awaits it after driving the channel from the test
  process.

  `async: false`: the request server is one named process for the whole node,
  and this file selects the real transport in application environment.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.RepositoryMetadata
  alias SddOrchestrator.RepositoryMetadata.Transport.Attachment
  alias SddOrchestratorWeb.WorkerSocket

  @endpoint SddOrchestratorWeb.Endpoint

  @capability "repository_metadata"
  @transport_key :repository_metadata_transport

  setup do
    # `config/test.exs` sets no default for this transport key, so it already
    # falls back to the unavailable stand-in unless a test overrides it. This
    # file proves the real one, so the choice is made here rather than assumed.
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
      task = Task.async(fn -> RepositoryMetadata.inspect(attrs) end)

      assert_push "repository_metadata", payload
      assert is_binary(payload["request_id"])
      assert payload["selection_ref"] == attrs.selection_ref
      assert payload["repository_provider"] == attrs.repository_provider
      assert payload["repository_id"] == attrs.repository_id
      assert payload["selected_root"] == attrs.selected_root
      assert {:ok, _expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])

      ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => payload["request_id"],
          "outcome" => "cancelled"
        })

      assert_reply ref, :ok, _reply, 2_000
      assert {:error, :cancelled} = Task.await(task)
    end

    test "no worker attached for the asked workspace resolves the blocked call at once",
         context do
      other_workspace = Ecto.UUID.generate()

      assert {:error, :worker_unavailable} =
               RepositoryMetadata.inspect(
                 request_attrs(%{workspace: other_workspace, worker_id: context.worker_id})
               )
    end

    test "a cancellation reaches the worker as its own push", context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryMetadata.inspect(attrs) end)

      assert_push "repository_metadata", payload
      request_id = payload["request_id"]

      # A requester's own process exit is the cancellation path; unlink first
      # so killing the task does not also take down this test process.
      Process.unlink(task.pid)
      Process.exit(task.pid, :kill)

      assert_push "repository_metadata_cancel", %{"request_id" => ^request_id}
    end
  end

  describe "answering" do
    test "a metadata result from the attachment the request went to resolves the blocked call",
         context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryMetadata.inspect(attrs) end)

      assert_push "repository_metadata", payload
      request_id = payload["request_id"]

      ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => request_id,
          "outcome" => "metadata",
          "repository_provider" => "github",
          "repository_id" => "org/repo",
          "root" => "normalized-root-token",
          "commit" => String.duplicate("a1", 20)
        })

      assert_reply ref, :ok, _reply, 2_000

      assert {:ok, result} = Task.await(task)
      assert result.repository_provider == "github"
      assert result.repository_id == "org/repo"
      assert result.root == "normalized-root-token"
      assert result.commit == String.duplicate("a1", 20)
    end

    test "a result from another attachment is refused and the blocked call keeps waiting",
         context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryMetadata.inspect(attrs) end)

      assert_push "repository_metadata", payload
      request_id = payload["request_id"]

      {:ok, _reply, other} = attach(Ecto.UUID.generate())

      foreign_ref =
        push(other, "repository_metadata_result", %{
          "request_id" => request_id,
          "outcome" => "metadata",
          "repository_provider" => "github",
          "repository_id" => "org/repo",
          "root" => "normalized-root-token",
          "commit" => String.duplicate("a1", 20)
        })

      assert_reply foreign_ref, :error, %{reason: "foreign_answer"}, 2_000

      # The wrong attachment's answer did not resolve the request: the
      # attachment the request actually went to can still close it.
      real_ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => request_id,
          "outcome" => "metadata",
          "repository_provider" => "github",
          "repository_id" => "org/repo",
          "root" => "normalized-root-token",
          "commit" => String.duplicate("a1", 20)
        })

      assert_reply real_ref, :ok, _reply, 2_000
      assert {:ok, result} = Task.await(task)
      assert result.repository_id == "org/repo"
    end

    test "an answer to a request nobody opened is refused", context do
      ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => Ecto.UUID.generate(),
          "outcome" => "cancelled"
        })

      assert_reply ref, :error, %{reason: "unknown_request"}, 2_000
    end
  end

  describe "capability" do
    test "a worker that did not negotiate repository_metadata is refused" do
      workspace = Ecto.UUID.generate()
      announced = List.delete(WorkerProtocol.capabilities(), @capability)

      {:ok, _reply, _channel} =
        attach(workspace, announcement: %{"capabilities" => announced})

      assert {:error, :worker_unavailable} =
               RepositoryMetadata.inspect(
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
    test "the pushed payload holds exactly the six allowed keys and nothing else", context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryMetadata.inspect(attrs) end)

      assert_push "repository_metadata", payload

      assert Enum.sort(Map.keys(payload)) == [
               "expires_at",
               "repository_id",
               "repository_provider",
               "request_id",
               "selected_root",
               "selection_ref"
             ]

      ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => payload["request_id"],
          "outcome" => "cancelled"
        })

      assert_reply ref, :ok, _reply, 2_000
      assert {:error, :cancelled} = Task.await(task)
    end

    test "an answer carrying an unrecognized key is refused before it reaches the requester",
         context do
      attrs = request_attrs(context)
      task = Task.async(fn -> RepositoryMetadata.inspect(attrs) end)

      assert_push "repository_metadata", payload
      request_id = payload["request_id"]

      tainted_ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => request_id,
          "outcome" => "metadata",
          "repository_provider" => "github",
          "repository_id" => "org/repo",
          "root" => "normalized-root-token",
          "commit" => String.duplicate("a1", 20),
          "path" => "/Users/person/code/orchestrator"
        })

      assert_reply tainted_ref, :error, %{reason: "invalid_result"}, 2_000

      # The refused frame never reached the requester: a clean answer for the
      # same request still resolves the blocked call.
      clean_ref =
        push(context.channel, "repository_metadata_result", %{
          "request_id" => request_id,
          "outcome" => "metadata",
          "repository_provider" => "github",
          "repository_id" => "org/repo",
          "root" => "normalized-root-token",
          "commit" => String.duplicate("a1", 20)
        })

      assert_reply clean_ref, :ok, _reply, 2_000
      assert {:ok, _result} = Task.await(task)
    end
  end

  defp request_attrs(context) do
    %{
      project_id: Ecto.UUID.generate(),
      repository_provider: "github",
      repository_id: "org/repo",
      device_workspace_id: context.workspace,
      worker_ref: context.worker_id,
      selection_ref: Ecto.UUID.generate(),
      selected_root: "root-token",
      scanner_contract_digest: String.duplicate("a1", 32),
      disclosure_digest: String.duplicate("b2", 32)
    }
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
