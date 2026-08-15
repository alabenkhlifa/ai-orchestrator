defmodule SddOrchestrator.ProjectAssistant.TurnAnswerStore do
  @moduledoc """
  Task 7's authoritative store for one fully composed turn: the question,
  its answer (or normalized failure/cancellation outcome), the stored
  context version it grounded on, its uncertainty markers, and its
  citations, all persisted atomically.

  This complements, and deliberately does not modify,
  `SddOrchestrator.ProjectAssistantStore` (Task 1): that module's
  `append_turn/4` remains a valid question-only insert used by Task 1's own
  proof, and `list_history/3` keeps returning whatever it always returned.
  A full turn — question plus answer, context version, markers, outcome,
  and citations — is only ever created through `persist/5` here, in one
  transaction (hosted) or one atomic multi-write (device), mirroring Task
  1's own conversation-creation and turn-sequencing logic exactly (lock or
  create the conversation, assign the next sequence, touch last activity)
  without reusing Task 1's private functions across a module boundary.

  Every operation revalidates the acting participant's current project
  participation on its own call into
  `SddOrchestrator.ProjectAssistant.Guard` (hosted) or the device workspace
  check (device) — nothing here caches an authorization result across
  calls, matching every other project-assistant surface.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.ProjectAssistant.Guard

  alias SddOrchestrator.ProjectAssistant.{
    DeviceProjectAssistantConversation,
    DeviceProjectAssistantTurn,
    ProjectAssistantConversation,
    ProjectAssistantTurn
  }

  alias SddOrchestrator.ProjectAssistant.TurnAnswerStore.{Device, Hosted}

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: Guard.actor()
  @type conversation :: ProjectAssistantConversation.t() | DeviceProjectAssistantConversation.t()
  @type turn :: ProjectAssistantTurn.t() | DeviceProjectAssistantTurn.t()

  @type answer_attrs :: %{
          answer_text: String.t() | nil,
          context_version: String.t() | nil,
          uncertainty_markers: [map()],
          outcome: String.t(),
          failure_reason: String.t() | nil,
          citations: [
            %{source_type: String.t(), reference: map(), excerpt: String.t() | nil}
          ]
        }

  @doc """
  Appends one complete question-and-answer turn (or cancellation/failure
  outcome) to the acting participant's own conversation, opening it first
  when needed, atomically inserting every citation, and advancing the
  conversation's last activity — exactly like
  `ProjectAssistantStore.append_turn/4` does for a bare question, extended
  with everything Task 7 owns.
  """
  @spec persist(authority(), String.t(), actor(), String.t(), answer_attrs()) ::
          {:ok, {conversation(), turn(), [term()]}} | {:error, :unauthorized | term()}
  def persist(%PersonalWorkspace{} = authority, project_id, actor, question_text, answer_attrs),
    do: Hosted.persist(authority, project_id, actor, question_text, answer_attrs)

  def persist(%DeviceWorkspace{} = authority, project_id, actor, question_text, answer_attrs),
    do: Device.persist(authority, project_id, actor, question_text, answer_attrs)

  def persist(_authority, _project_id, _actor, _question_text, _answer_attrs),
    do: {:error, :unauthorized}
end
