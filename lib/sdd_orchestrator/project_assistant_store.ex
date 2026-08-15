defmodule SddOrchestrator.ProjectAssistantStore do
  @moduledoc """
  Shared authoritative store for one participant-private project-assistant
  conversation and its ordered turns.

  Hosted and device authorities implement the same logical operations behind
  one dispatch, mirroring `SddOrchestrator.SpecificationStore`. Every
  operation revalidates the acting participant's current project
  participation on its own call into `SddOrchestrator.ProjectAssistant.Guard`
  (hosted) or the device workspace check (device) — nothing here caches an
  authorization result across calls. An unsupported authority, an
  unauthorized actor, and a nonexistent project all fail the same way, so a
  denied caller learns nothing about what exists.

  This store owns identity, ordering, and authorization only. The answer,
  citations, context-version references, runtime state, and uncertainty
  markers a later task adds belong to their own migrations and modules; nothing
  here creates a shared-project-activity projection.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}

  alias SddOrchestrator.ProjectAssistant.{
    DeviceProjectAssistantConversation,
    DeviceProjectAssistantTurn,
    Guard,
    ProjectAssistantConversation,
    ProjectAssistantTurn
  }

  alias SddOrchestrator.ProjectAssistant.ProjectAssistantStore.{Device, Hosted}

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: Guard.actor()
  @type conversation :: ProjectAssistantConversation.t() | DeviceProjectAssistantConversation.t()
  @type turn :: ProjectAssistantTurn.t() | DeviceProjectAssistantTurn.t()

  @doc "Creates or retrieves the acting participant's own conversation."
  @spec open_conversation(authority(), String.t(), actor()) ::
          {:ok, conversation()} | {:error, :unauthorized | term()}
  def open_conversation(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.open_conversation(authority, project_id, actor)

  def open_conversation(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.open_conversation(authority, project_id, actor)

  def open_conversation(_authority, _project_id, _actor), do: {:error, :unauthorized}

  @doc """
  Lists the acting participant's own private turn history, oldest first.

  Returns `{:ok, nil, []}` when the participant is authorized but has not
  opened a conversation yet — history absence is not an error.
  """
  @spec list_history(authority(), String.t(), actor()) ::
          {:ok, conversation() | nil, [turn()]} | {:error, :unauthorized}
  def list_history(%PersonalWorkspace{} = authority, project_id, actor),
    do: Hosted.list_history(authority, project_id, actor)

  def list_history(%DeviceWorkspace{} = authority, project_id, actor),
    do: Device.list_history(authority, project_id, actor)

  def list_history(_authority, _project_id, _actor), do: {:error, :unauthorized}

  @doc """
  Appends one turn to the acting participant's own conversation, opening it
  first when needed, and atomically advances the conversation's last
  activity.
  """
  @spec append_turn(authority(), String.t(), actor(), String.t()) ::
          {:ok, {conversation(), turn()}} | {:error, :unauthorized | term()}
  def append_turn(%PersonalWorkspace{} = authority, project_id, actor, question_text),
    do: Hosted.append_turn(authority, project_id, actor, question_text)

  def append_turn(%DeviceWorkspace{} = authority, project_id, actor, question_text),
    do: Device.append_turn(authority, project_id, actor, question_text)

  def append_turn(_authority, _project_id, _actor, _question_text), do: {:error, :unauthorized}

  @doc """
  Immediately deletes the acting participant's own conversation, its turns,
  and its boundary confirmation. Idempotent: deleting an already-absent
  conversation still succeeds.

  specs/12 Task 9 (AC-21) composes `SddOrchestrator.ProjectAssistantBoundaryStore.delete_confirmation/3`
  here rather than editing Task 1's or Task 2's own store internals: a
  deleted conversation leaves no reason to keep the matching
  `AssistantBoundaryConfirmation` (Task 1's own conversation delete never
  touched it, since the confirmation did not exist yet when Task 1 was
  built), and every existing caller of this immediate-delete action —
  including Task 8's panel — gets the complete cleanup automatically.
  """
  @spec delete_conversation(authority(), String.t(), actor()) :: :ok | {:error, :unauthorized}
  def delete_conversation(%PersonalWorkspace{} = authority, project_id, actor) do
    with :ok <- Hosted.delete_conversation(authority, project_id, actor) do
      SddOrchestrator.ProjectAssistantBoundaryStore.delete_confirmation(
        authority,
        project_id,
        actor
      )
    end
  end

  def delete_conversation(%DeviceWorkspace{} = authority, project_id, actor) do
    with :ok <- Device.delete_conversation(authority, project_id, actor) do
      SddOrchestrator.ProjectAssistantBoundaryStore.delete_confirmation(
        authority,
        project_id,
        actor
      )
    end
  end

  def delete_conversation(_authority, _project_id, _actor), do: {:error, :unauthorized}
end
