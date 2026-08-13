defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantStore.Hosted do
  @moduledoc false

  import Ecto.Query

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.ProjectAssistant.Guard
  alias SddOrchestrator.ProjectAssistant.{ProjectAssistantConversation, ProjectAssistantTurn}
  alias SddOrchestrator.Repo

  @spec open_conversation(PersonalWorkspace.t(), String.t(), Guard.actor()) ::
          {:ok, ProjectAssistantConversation.t()} | {:error, :unauthorized | term()}
  def open_conversation(%PersonalWorkspace{}, project_id, actor) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :open_panel) do
      open_or_create(project_id, member.account_id)
    end
  end

  @spec list_history(PersonalWorkspace.t(), String.t(), Guard.actor()) ::
          {:ok, ProjectAssistantConversation.t() | nil, [ProjectAssistantTurn.t()]}
          | {:error, :unauthorized}
  def list_history(%PersonalWorkspace{}, project_id, actor) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :read_history) do
      {conversation, turns} = fetch_history(project_id, member.account_id)
      {:ok, conversation, turns}
    end
  end

  @spec append_turn(PersonalWorkspace.t(), String.t(), Guard.actor(), String.t()) ::
          {:ok, {ProjectAssistantConversation.t(), ProjectAssistantTurn.t()}}
          | {:error, :unauthorized | term()}
  def append_turn(%PersonalWorkspace{}, project_id, actor, question_text) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :open_panel) do
      do_append_turn(project_id, member.account_id, question_text)
    end
  end

  @spec delete_conversation(PersonalWorkspace.t(), String.t(), Guard.actor()) ::
          :ok | {:error, :unauthorized}
  def delete_conversation(%PersonalWorkspace{}, project_id, actor) do
    with {:ok, member} <- Guard.authorize_action(project_id, actor, :delete) do
      do_delete(project_id, member.account_id)
    end
  end

  defp open_or_create(project_id, account_id) do
    case get_by_identity(project_id, account_id) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :not_found} -> insert_conversation(project_id, account_id)
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

  # A racing panel-open or first question from the same participant loses the
  # unique-index race rather than being refused: the loser simply reads what
  # the winner already committed.
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
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp fetch_history(project_id, account_id) do
    case get_by_identity(project_id, account_id) do
      {:ok, conversation} -> {conversation, turns_for(conversation.id)}
      {:error, :not_found} -> {nil, []}
    end
  end

  defp turns_for(conversation_id) do
    ProjectAssistantTurn
    |> where([t], t.conversation_id == ^conversation_id)
    |> order_by([t], asc: t.sequence)
    |> Repo.all()
  end

  defp do_append_turn(project_id, account_id, question_text) do
    Repo.transaction(fn ->
      conversation = lock_or_create!(project_id, account_id)
      next_sequence = next_sequence(conversation.id)

      turn =
        %ProjectAssistantTurn{}
        |> ProjectAssistantTurn.create_changeset(%{
          conversation_id: conversation.id,
          project_id: project_id,
          sequence: next_sequence,
          question_text: question_text
        })
        |> Repo.insert()
        |> case do
          {:ok, turn} -> turn
          {:error, changeset} -> Repo.rollback(changeset)
        end

      updated_conversation =
        conversation
        |> ProjectAssistantConversation.touch_changeset(now())
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {updated_conversation, turn}
    end)
  end

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

  defp next_sequence(conversation_id) do
    (Repo.one(
       from t in ProjectAssistantTurn,
         where: t.conversation_id == ^conversation_id,
         select: max(t.sequence)
     ) || 0) + 1
  end

  defp do_delete(project_id, account_id) do
    case get_by_identity(project_id, account_id) do
      {:ok, conversation} ->
        Repo.delete(conversation)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
