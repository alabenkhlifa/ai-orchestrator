defmodule SddOrchestrator.Privacy.ProjectAssistantDataUsePolicy do
  @moduledoc """
  Fail-closed purpose and recipient boundary for specs/12 (project-assistant)
  data (AC-19, AC-20 — "no analytics or training reuse" and prohibited-use
  owned surfaces).

  This policy covers the participant-private conversation, turn, citation,
  and boundary-confirmation records, plus the destination-local
  `ProjectContextProjection` cache, that `SddOrchestrator.Privacy.ProjectAssistantProcessingInventory`
  classifies.

  ## Why `:model_provider` is narrowly allowed here, unlike `SddOrchestrator.Privacy.AIRuntimeDataUsePolicy`

  `AIRuntimeDataUsePolicy` blanket-prohibits `:model_provider` for every AI-
  runtime *governance* record (the connection reference, catalog, quota,
  pinned session, ledger, and observation) because none of those records'
  content is ever the thing sent to the provider — the provider is
  contacted only by the user's own worker-local client for the actual work,
  and the governance records describing that work are a separate thing
  that must never become provider input themselves.

  Project-assistant is different in exactly the way that module's own
  moduledoc anticipates needing a fresh decision for: `question_text` and
  `answer_text` are not governance metadata *about* a model call, they are
  the literal content of one. Answering the participant's own question
  through their own configured personal AI connection is this feature's
  entire purpose (design.md's Outcome). Blanket-prohibiting `:model_provider`
  here would make the feature impossible to implement, not more private.

  The allowed route is therefore deliberately the narrowest one that still
  lets the feature work: `:model_provider` may receive `question_text` and
  `answer_text` under the single purpose `:answer_participant_question`,
  and nothing else — never citations, never another participant's
  conversation, never the boundary confirmation, never the stored-context
  projection's raw content beyond what a turn's own grounding step already
  includes, and never for any purpose other than answering that one
  question. `:model_provider` remains prohibited for every other purpose
  (`:retention_cleanup`, `:verified_rights`, and implicitly every
  unenumerated one, since `authorize/3` is fail-closed by construction) and
  every other data class.

  Across the five record classes, `:retention_cleanup` names only
  `:approved_operations` and `:verified_rights` names only
  `:verified_rights_operator` — the same least-privilege shape
  `AIRuntimeDataUsePolicy` and `SddOrchestrator.Privacy.DeliveryDataUsePolicy`
  already establish: support and operations personnel get a lifecycle and
  rights route, never a content-reading one.
  """

  @prohibited_purposes [
    :advertising,
    :analytics,
    :identity_tracking,
    :model_training,
    :unrelated_product_improvement
  ]

  @prohibited_consumers [
    :advertising_network,
    :analytics_processor,
    :coding_agent
  ]

  @allowed %{
    project_assistant_conversation: %{
      conversation_lifecycle: [:owning_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    project_assistant_turn: %{
      answer_participant_question: [:owning_participant, :model_provider],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    project_assistant_citation: %{
      citation_presentation: [:owning_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    assistant_boundary_confirmation: %{
      boundary_disclosure: [:owning_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    project_context_projection: %{
      stored_context_grounding: [:current_project_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    }
  }

  @anonymous_aggregate_boundary %{
    current_processing: :prohibited,
    future_requirement: :aggregate_and_genuinely_anonymous,
    prohibited_identifiers: [
      :user,
      :device,
      :workspace,
      :project,
      :repository,
      :conversation,
      :provider,
      :session,
      :content,
      :network,
      :stable_pseudonymous_identifier
    ]
  }

  @type data_class ::
          :project_assistant_conversation
          | :project_assistant_turn
          | :project_assistant_citation
          | :assistant_boundary_confirmation
          | :project_context_projection

  @doc """
  Authorizes only an explicitly approved project-assistant purpose and
  recipient.

  `:model_provider` is authorized only for `project_assistant_turn` under
  the single `answer_participant_question` purpose (see moduledoc); every
  other data class or purpose refuses it through the same fail-closed
  `not_authorized` path an unlisted route always takes, with no separate
  `:model_provider`-specific prohibition list required.
  """
  @spec authorize(data_class(), atom(), atom()) ::
          :ok
          | {:error, :secondary_use_prohibited | :consumer_prohibited | :not_authorized}
  def authorize(_data_class, purpose, _consumer) when purpose in @prohibited_purposes,
    do: {:error, :secondary_use_prohibited}

  def authorize(_data_class, _purpose, consumer) when consumer in @prohibited_consumers,
    do: {:error, :consumer_prohibited}

  def authorize(data_class, purpose, consumer) do
    with purposes when is_map(purposes) <- Map.get(@allowed, data_class),
         consumers when is_list(consumers) <- Map.get(purposes, purpose),
         true <- consumer in consumers do
      :ok
    else
      _not_authorized -> {:error, :not_authorized}
    end
  end

  @doc "The current prohibition and minimum contract for any future analytics proposal."
  @spec anonymous_aggregate_boundary() :: map()
  def anonymous_aggregate_boundary, do: @anonymous_aggregate_boundary

  @doc "The project-assistant data classes governed by the fail-closed boundary."
  @spec data_classes() :: [data_class()]
  def data_classes, do: Map.keys(@allowed)

  @doc "The approved purpose-to-consumer routes, keyed by data class."
  @spec allowed_routes() :: %{data_class() => %{atom() => [atom()]}}
  def allowed_routes, do: @allowed

  @doc "The secondary-use purposes refused for every project-assistant data class."
  @spec prohibited_purposes() :: [atom()]
  def prohibited_purposes, do: @prohibited_purposes

  @doc "The recipients refused for every project-assistant data class and purpose."
  @spec prohibited_consumers() :: [atom()]
  def prohibited_consumers, do: @prohibited_consumers
end
