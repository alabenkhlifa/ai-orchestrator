defmodule SddOrchestrator.ProjectAssistant.TurnAnswerStore.Device do
  @moduledoc """
  The worker-owned adapter for a device-authoritative project's full
  question-and-answer turn and its citations.

  Deliberately duplicated from, and never calling into,
  `SddOrchestrator.ProjectAssistant.ProjectAssistantStore.Device` (Task 1):
  that module's `append_turn/4` keeps its original bare question-only
  contract and its own `decode_turn/1` still only ever decrypts
  `question_text` through `DeviceProjectAssistantTurn.from_value/2`. A full
  answered turn — question, answer, context version, markers, outcome, and
  citations — is written and read only through this module, using the
  `to_value/3` and `from_value/3` clauses Task 7 added to
  `DeviceProjectAssistantTurn` alongside (never replacing) Task 1's
  originals.

  Citations go through the same generic device-delivery seam every other
  device-authoritative record uses, keyed by `:project_assistant_citation`.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices

  alias SddOrchestrator.ProjectAssistant.{
    DeviceProjectAssistantCitation,
    DeviceProjectAssistantConversation,
    DeviceProjectAssistantTurn,
    Guard
  }

  alias SddOrchestrator.Vault

  @spec persist(DeviceWorkspace.t(), String.t(), Guard.actor(), String.t(), map()) ::
          {:ok,
           {DeviceProjectAssistantConversation.t(), DeviceProjectAssistantTurn.t(),
            [DeviceProjectAssistantCitation.t()]}}
          | {:error, :unauthorized | term()}
  def persist(%DeviceWorkspace{} = authority, project_id, _actor, question_text, answer_attrs) do
    with {:ok, member} <- authorize(authority, project_id) do
      do_persist(project_id, member.workspace_id, question_text, answer_attrs)
    end
  end

  defp authorize(%DeviceWorkspace{id: authority_id}, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"}} <- Devices.get_project(project_id) do
      {:ok, %{workspace_id: authority_id}}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp do_persist(project_id, workspace_id, question_text, answer_attrs) do
    with {:ok, valid_text} <- validate_question_text(question_text),
         {:ok, conversation} <- open_or_create(project_id, workspace_id),
         {:ok, sealed_question} <- Vault.encrypt(valid_text),
         {:ok, sealed_answer} <- seal_answer(answer_attrs.answer_text) do
      next_sequence = next_sequence(project_id, conversation.id)
      now = now()

      turn = %DeviceProjectAssistantTurn{
        id: Ecto.UUID.generate(),
        conversation_id: conversation.id,
        project_id: project_id,
        sequence: next_sequence,
        question_text: valid_text,
        inserted_at: now,
        answer_text: answer_attrs.answer_text,
        context_version: answer_attrs.context_version,
        uncertainty_markers: answer_attrs.uncertainty_markers,
        outcome: answer_attrs.outcome,
        failure_reason: answer_attrs.failure_reason
      }

      turn_value = DeviceProjectAssistantTurn.to_value(turn, sealed_question, sealed_answer)

      {:ok, citations, citation_writes} =
        build_citation_writes(project_id, turn.id, answer_attrs.citations)

      touched = %{
        conversation
        | last_activity_at: now,
          updated_at: now,
          state_version: conversation.state_version + 1
      }

      conversation_value = DeviceProjectAssistantConversation.to_value(touched)

      writes =
        [
          {:put, :project_assistant_conversation, conversation.id, conversation_value,
           conversation.state_version},
          {:put, :project_assistant_turn, turn.id, turn_value, nil}
        ] ++ citation_writes

      case Devices.commit_delivery(project_id, writes) do
        {:ok, _applied} -> {:ok, {touched, turn, citations}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp seal_answer(nil), do: {:ok, nil}
  defp seal_answer(text) when is_binary(text), do: Vault.encrypt(text)

  defp build_citation_writes(project_id, turn_id, citation_attrs_list) do
    now = now()

    {citations, writes} =
      citation_attrs_list
      |> Enum.map(fn citation_attrs ->
        citation = %DeviceProjectAssistantCitation{
          id: Ecto.UUID.generate(),
          turn_id: turn_id,
          project_id: project_id,
          source_type: citation_attrs.source_type,
          reference: citation_attrs.reference,
          excerpt: citation_attrs.excerpt,
          inserted_at: now
        }

        {:ok, sealed_excerpt} = seal_answer(citation_attrs.excerpt)
        value = DeviceProjectAssistantCitation.to_value(citation, sealed_excerpt)
        write = {:put, :project_assistant_citation, citation.id, value, nil}

        {citation, write}
      end)
      |> Enum.unzip()

    {:ok, citations, writes}
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

  defp next_sequence(project_id, conversation_id) do
    project_id
    |> Devices.list_delivery(:project_assistant_turn)
    |> Enum.filter(&(&1["conversation_id"] == conversation_id))
    |> Enum.map(& &1["sequence"])
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
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
