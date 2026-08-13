defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantStore.Device do
  @moduledoc """
  The worker-owned adapter for a device-authoritative project's private
  conversation and turns.

  Nothing this adapter writes reaches the hosted database. Records go
  through the same generic device-delivery seam every other
  device-authoritative record uses (`SddOrchestrator.Devices.commit_delivery/2`
  and friends), so the device store needs no project-assistant-specific
  operation of its own.

  A device-authoritative project has no hosted owner or participant of its
  own (`SddOrchestrator.Participation.owner/1`), so the acting identity here
  is the device workspace that owns this local store, reverified fresh on
  every call exactly like `SpecificationStore.Device` reverifies it for
  specifications. There is only ever one possible participant, so the
  conversation's stable identity and its delivery-seam record id are both the
  device workspace id.

  The device store's file is not encrypted, so the question text is sealed
  with `SddOrchestrator.Vault` before it is written and opened again on read
  — the same treatment a device-local artifact and import upload get.

  Deletion replaces the conversation and its turns with tombstones rather
  than deleting a key, because the delivery seam applies puts and nothing
  else. A tombstone carries no content: every read treats it as absent, so a
  later re-open starts a fresh conversation rather than restoring history.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices

  alias SddOrchestrator.ProjectAssistant.{
    DeviceProjectAssistantConversation,
    DeviceProjectAssistantTurn,
    Guard
  }

  alias SddOrchestrator.Vault

  @tombstone %{"deleted" => true}

  @spec open_conversation(DeviceWorkspace.t(), String.t(), Guard.actor()) ::
          {:ok, DeviceProjectAssistantConversation.t()} | {:error, :unauthorized | term()}
  def open_conversation(%DeviceWorkspace{} = authority, project_id, _actor) do
    with {:ok, member} <- authorize(authority, project_id, :open_panel) do
      open_or_create(project_id, member.workspace_id)
    end
  end

  @spec list_history(DeviceWorkspace.t(), String.t(), Guard.actor()) ::
          {:ok, DeviceProjectAssistantConversation.t() | nil, [DeviceProjectAssistantTurn.t()]}
          | {:error, :unauthorized}
  def list_history(%DeviceWorkspace{} = authority, project_id, _actor) do
    with {:ok, member} <- authorize(authority, project_id, :read_history) do
      {conversation, turns} = fetch_history(project_id, member.workspace_id)
      {:ok, conversation, turns}
    end
  end

  @spec append_turn(DeviceWorkspace.t(), String.t(), Guard.actor(), String.t()) ::
          {:ok, {DeviceProjectAssistantConversation.t(), DeviceProjectAssistantTurn.t()}}
          | {:error, :unauthorized | term()}
  def append_turn(%DeviceWorkspace{} = authority, project_id, _actor, question_text) do
    with {:ok, member} <- authorize(authority, project_id, :open_panel) do
      do_append_turn(project_id, member.workspace_id, question_text)
    end
  end

  @spec delete_conversation(DeviceWorkspace.t(), String.t(), Guard.actor()) ::
          :ok | {:error, :unauthorized}
  def delete_conversation(%DeviceWorkspace{} = authority, project_id, _actor) do
    with {:ok, member} <- authorize(authority, project_id, :delete) do
      do_delete(project_id, member.workspace_id)
    end
  end

  defp authorize(%DeviceWorkspace{id: authority_id}, project_id, action) do
    with true <- action in Guard.protected_actions(),
         {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"}} <- Devices.get_project(project_id) do
      {:ok, %{workspace_id: authority_id}}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp open_or_create(project_id, workspace_id) do
    case Devices.get_delivery(project_id, :project_assistant_conversation, workspace_id) do
      {:ok, value} ->
        case DeviceProjectAssistantConversation.from_value(value) do
          {:ok, conversation} -> {:ok, conversation}
          {:error, _reason} -> insert_conversation(project_id, workspace_id)
        end

      {:error, :not_found} ->
        insert_conversation(project_id, workspace_id)
    end
  end

  defp insert_conversation(project_id, workspace_id) do
    now = now()

    conversation = %DeviceProjectAssistantConversation{
      id: workspace_id,
      project_id: project_id,
      workspace_id: workspace_id,
      last_activity_at: now,
      state_version: 1,
      inserted_at: now,
      updated_at: now
    }

    value = DeviceProjectAssistantConversation.to_value(conversation)

    case Devices.commit_delivery(project_id, [
           {:put, :project_assistant_conversation, workspace_id, value, nil}
         ]) do
      {:ok, _applied} -> {:ok, conversation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_history(project_id, workspace_id) do
    case Devices.get_delivery(project_id, :project_assistant_conversation, workspace_id) do
      {:ok, value} ->
        case DeviceProjectAssistantConversation.from_value(value) do
          {:ok, conversation} -> {conversation, turns_for(project_id, conversation.id)}
          {:error, _reason} -> {nil, []}
        end

      {:error, :not_found} ->
        {nil, []}
    end
  end

  defp turns_for(project_id, conversation_id) do
    project_id
    |> Devices.list_delivery(:project_assistant_turn)
    |> Enum.filter(&(&1["conversation_id"] == conversation_id))
    |> Enum.flat_map(&decode_turn/1)
    |> Enum.sort_by(& &1.sequence)
  end

  defp decode_turn(value) do
    with {:ok, plaintext} <- Vault.decrypt(value["question_text"]),
         {:ok, turn} <- DeviceProjectAssistantTurn.from_value(value, plaintext) do
      [turn]
    else
      _invalid -> []
    end
  end

  defp next_sequence(project_id, conversation_id) do
    project_id
    |> Devices.list_delivery(:project_assistant_turn)
    |> Enum.filter(&(&1["conversation_id"] == conversation_id))
    |> Enum.map(& &1["sequence"])
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp do_append_turn(project_id, workspace_id, question_text) do
    with {:ok, valid_text} <- validate_question_text(question_text),
         {:ok, conversation} <- open_or_create(project_id, workspace_id),
         {:ok, sealed} <- Vault.encrypt(valid_text) do
      next_sequence = next_sequence(project_id, conversation.id)
      now = now()

      turn = %DeviceProjectAssistantTurn{
        id: Ecto.UUID.generate(),
        conversation_id: conversation.id,
        project_id: project_id,
        sequence: next_sequence,
        question_text: valid_text,
        inserted_at: now
      }

      turn_value = DeviceProjectAssistantTurn.to_value(turn, sealed)

      touched = %{
        conversation
        | last_activity_at: now,
          updated_at: now,
          state_version: conversation.state_version + 1
      }

      conversation_value = DeviceProjectAssistantConversation.to_value(touched)

      writes = [
        {:put, :project_assistant_conversation, conversation.id, conversation_value,
         conversation.state_version},
        {:put, :project_assistant_turn, turn.id, turn_value, nil}
      ]

      case Devices.commit_delivery(project_id, writes) do
        {:ok, _applied} -> {:ok, {touched, turn}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_delete(project_id, workspace_id) do
    case Devices.get_delivery(project_id, :project_assistant_conversation, workspace_id) do
      {:ok, value} ->
        turn_ids =
          project_id
          |> Devices.list_delivery(:project_assistant_turn)
          |> Enum.filter(&(&1["conversation_id"] == workspace_id))
          |> Enum.map(& &1["id"])

        writes =
          [
            {:put, :project_assistant_conversation, workspace_id, @tombstone,
             value["state_version"]}
          ] ++ Enum.map(turn_ids, &{:put, :project_assistant_turn, &1, @tombstone, nil})

        case Devices.commit_delivery(project_id, writes) do
          {:ok, _applied} -> :ok
          {:error, _reason} -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp validate_question_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :invalid_question}
      Regex.match?(~r/\p{Cc}/u, trimmed) -> {:error, :invalid_question}
      byte_size(trimmed) > 4_000 -> {:error, :invalid_question}
      true -> {:ok, trimmed}
    end
  end

  defp validate_question_text(_text), do: {:error, :invalid_question}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
