defmodule SddOrchestratorWeb.WorkerWorkspaceChannelRepositorySelectionTest do
  @moduledoc """
  Task 2 proof: a selection request rides the Mac-scoped attachment both ways.

  The properties under test are the ones AC-08 decides. A request reaches the
  worker attached for its own workspace; only that attachment can answer it; an
  answer from another attachment is refused and reaches nobody; a worker that
  did not negotiate the folder-picker vocabulary is refused before a panel is
  ever promised; and what crosses the wire is identities and a folder name,
  never a location.

  `async: false`: the request server is one named process for the whole node,
  and this file selects the real transport in application environment.
  """
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestrator.RepositorySelection.Transport.Attachment
  alias SddOrchestratorWeb.WorkerSocket

  @endpoint SddOrchestratorWeb.Endpoint

  @capability "repository_selection"
  @transport_key :repository_selection_transport

  setup do
    # `config/test.exs` may select the stand-in transport, and this file proves
    # the real one, so the choice is made here rather than assumed.
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
      {:ok, request_id} =
        RepositorySelection.request(scope(context), context.worker_id,
          candidates: [%{ref: "project-a", identity: "local-repo:v1:salt:digest"}],
          generate: true
        )

      assert_push "repository_selection", payload
      assert payload["request_id"] == request_id
      assert payload["generate"] == true

      assert payload["candidates"] == [
               %{"ref" => "project-a", "identity" => "local-repo:v1:salt:digest"}
             ]

      assert {:ok, _expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
    end

    test "no worker attached for the asked workspace refuses the request", context do
      other_workspace = Ecto.UUID.generate()

      assert {:error, :no_worker} =
               RepositorySelection.request(
                 %{device_workspace_id: other_workspace},
                 context.worker_id
               )
    end

    test "a cancellation reaches the worker as its own push", context do
      {:ok, request_id} = RepositorySelection.request(scope(context), context.worker_id)
      assert_push "repository_selection", _request

      assert :ok = RepositorySelection.cancel(request_id)

      assert_push "repository_selection_cancel", cancellation
      assert cancellation == %{"request_id" => request_id}
      assert_receive {:repository_selection, ^request_id, :cancelled}
    end
  end

  describe "answering" do
    test "a result from the attachment the request went to reaches the requester", context do
      {:ok, request_id} =
        RepositorySelection.request(scope(context), context.worker_id,
          candidates: [%{ref: "project-a", identity: "local-repo:v1:salt:digest"}],
          generate: true
        )

      assert_push "repository_selection", _payload

      ref =
        push(context.channel, "repository_selection_result", %{
          "request_id" => request_id,
          "outcome" => "selected",
          "folder_name" => "orchestrator",
          "matches" => ["project-a"],
          "identity" => "local-repo:v1:fresh:digest"
        })

      assert_reply ref, :ok, _reply, 2_000

      assert_receive {:repository_selection, ^request_id,
                      {:selected, %SelectionResult{} = result}}

      assert result.folder_name == "orchestrator"
      assert result.matches == ["project-a"]
      assert result.identity == "local-repo:v1:fresh:digest"
    end

    test "a result from another attachment is refused and reaches nobody", context do
      {:ok, request_id} = RepositorySelection.request(scope(context), context.worker_id)
      assert_push "repository_selection", _payload

      {:ok, _reply, other} = attach(Ecto.UUID.generate())

      ref =
        push(other, "repository_selection_result", %{
          "request_id" => request_id,
          "outcome" => "selected",
          "folder_name" => "somebody-elses-repo"
        })

      assert_reply ref, :error, %{reason: "foreign_answer"}, 2_000
      refute_receive {:repository_selection, ^request_id, _outcome}, 100
    end

    test "an answer to a request nobody opened is refused", context do
      ref =
        push(context.channel, "repository_selection_result", %{
          "request_id" => Ecto.UUID.generate(),
          "outcome" => "cancelled"
        })

      assert_reply ref, :error, %{reason: "unknown_request"}, 2_000
    end

    test "a refused answer leaves the attachment in place", context do
      ref = push(context.channel, "repository_selection_result", %{"outcome" => "selected"})

      assert_reply ref, :error, _reason, 2_000

      {:ok, request_id} = RepositorySelection.request(scope(context), context.worker_id)
      assert_push "repository_selection", payload
      assert payload["request_id"] == request_id
    end
  end

  describe "capability" do
    test "a worker that did not negotiate the folder picker is refused" do
      workspace = Ecto.UUID.generate()
      announced = List.delete(WorkerProtocol.capabilities(), @capability)

      {:ok, _reply, _channel} =
        attach(workspace, announcement: %{"capabilities" => announced})

      assert {:error, :worker_needs_update} =
               RepositorySelection.request(
                 %{device_workspace_id: workspace},
                 DeliveryProtocolFixtures.worker_id()
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
    test "the pushed payload holds identities and nothing that spells a place", context do
      {:ok, _request_id} =
        RepositorySelection.request(scope(context), context.worker_id,
          candidates: [%{ref: "project-a", identity: "local-repo:v1:salt:digest"}],
          generate: true
        )

      assert_push "repository_selection", payload

      assert Enum.sort(Map.keys(payload)) == [
               "candidates",
               "expires_at",
               "generate",
               "request_id"
             ]

      refute Enum.any?(strings(payload), &String.contains?(&1, "/"))
    end

    test "an answer carrying a path is refused before it reaches the requester", context do
      {:ok, request_id} = RepositorySelection.request(scope(context), context.worker_id)
      assert_push "repository_selection", _payload

      ref =
        push(context.channel, "repository_selection_result", %{
          "request_id" => request_id,
          "outcome" => "selected",
          "folder_name" => "orchestrator",
          "path" => "/Users/person/code/orchestrator"
        })

      assert_reply ref, :error, %{reason: "invalid_result"}, 2_000
      refute_receive {:repository_selection, ^request_id, _outcome}, 100
    end

    test "an answer whose folder name is really a path is refused", context do
      {:ok, request_id} = RepositorySelection.request(scope(context), context.worker_id)
      assert_push "repository_selection", _payload

      ref =
        push(context.channel, "repository_selection_result", %{
          "request_id" => request_id,
          "outcome" => "selected",
          "folder_name" => "/Users/person/code/orchestrator"
        })

      assert_reply ref, :error, %{reason: "invalid_result"}, 2_000
      refute_receive {:repository_selection, ^request_id, _outcome}, 100
    end
  end

  defp scope(context), do: %{device_workspace_id: context.workspace}

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

  # Every string anywhere in the payload, so a location cannot hide inside a
  # nested candidate.
  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)

  defp strings(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} -> strings(key) ++ strings(nested) end)
  end

  defp strings(_value), do: []
end
