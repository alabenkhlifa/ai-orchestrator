defmodule SddOrchestrator.ProjectAssistant.TurnAnswerStore.Hosted do
  @moduledoc false

  import Ecto.Query

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.ProjectAssistant.Guard

  alias SddOrchestrator.ProjectAssistant.{
    ProjectAssistantCitation,
    ProjectAssistantConversation,
    ProjectAssistantTurn
  }

  alias SddOrchestrator.Repo

  @spec persist(PersonalWorkspace.t(), String.t(), Guard.actor(), String.t(), map()) ::
          {:ok,
           {ProjectAssistantConversation.t(), ProjectAssistantTurn.t(),
            [ProjectAssistantCitation.t()]}}
          | {:error, :unauthorized | term()}
  def persist(%PersonalWorkspace{}, project_id, actor, question_text, answer_attrs) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :open_panel) do
      do_persist(project_id, member.account_id, question_text, answer_attrs)
    end
  end

  defp do_persist(project_id, account_id, question_text, answer_attrs) do
    Repo.transaction(fn ->
      conversation = lock_or_create!(project_id, account_id)
      next_sequence = next_sequence(conversation.id)

      turn = insert_turn!(conversation, project_id, next_sequence, question_text, answer_attrs)
      citations = insert_citations!(turn, project_id, answer_attrs.citations)
      updated_conversation = touch!(conversation)

      {updated_conversation, turn, citations}
    end)
  end

  defp insert_turn!(conversation, project_id, sequence, question_text, answer_attrs) do
    %ProjectAssistantTurn{}
    |> ProjectAssistantTurn.create_changeset(%{
      conversation_id: conversation.id,
      project_id: project_id,
      sequence: sequence,
      question_text: question_text,
      answer_text: answer_attrs.answer_text,
      context_version: answer_attrs.context_version,
      uncertainty_markers: answer_attrs.uncertainty_markers,
      outcome: answer_attrs.outcome,
      failure_reason: answer_attrs.failure_reason
    })
    |> Repo.insert()
    |> case do
      {:ok, turn} -> turn
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_citations!(turn, project_id, citations) do
    Enum.map(citations, fn citation_attrs ->
      %ProjectAssistantCitation{}
      |> ProjectAssistantCitation.create_changeset(%{
        turn_id: turn.id,
        project_id: project_id,
        source_type: citation_attrs.source_type,
        reference: citation_attrs.reference,
        excerpt: citation_attrs.excerpt
      })
      |> Repo.insert()
      |> case do
        {:ok, citation} -> citation
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp touch!(conversation) do
    conversation
    |> ProjectAssistantConversation.touch_changeset(now())
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Deliberately duplicated from `ProjectAssistantStore.Hosted` (Task 1)
  # rather than calling across that module boundary: Task 1's own store
  # remains untouched and its `append_turn/4` keeps its original bare
  # question-only contract, while this store owns the full
  # question-plus-answer transaction end to end.
  defp lock_or_create!(project_id, account_id) do
    locked =
      ProjectAssistantConversation
      |> where([c], c.project_id == ^project_id and c.account_id == ^account_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case locked do
      nil ->
        case insert_conversation(project_id, account_id) do
          {:ok, conversation} -> conversation
          {:error, changeset} -> Repo.rollback(changeset)
        end

      conversation ->
        conversation
    end
  end

  defp insert_conversation(project_id, account_id) do
    %ProjectAssistantConversation{}
    |> ProjectAssistantConversation.create_changeset(%{
      project_id: project_id,
      account_id: account_id,
      last_activity_at: now()
    })
    |> Repo.insert()
    |> case do
      {:ok, conversation} -> {:ok, conversation}
      {:error, changeset} -> resolve_create_retry(project_id, account_id, changeset)
    end
  end

  defp resolve_create_retry(project_id, account_id, changeset) do
    case get_by_identity(project_id, account_id) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :not_found} -> {:error, changeset}
    end
  end

  defp get_by_identity(project_id, account_id) do
    ProjectAssistantConversation
    |> where([c], c.project_id == ^project_id and c.account_id == ^account_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp next_sequence(conversation_id) do
    (Repo.one(
       from t in ProjectAssistantTurn,
         where: t.conversation_id == ^conversation_id,
         select: max(t.sequence)
     ) || 0) + 1
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
