defmodule SddOrchestrator.Privacy.ProjectAssistantProcessingInventory do
  @moduledoc """
  The mechanically validated specs/12 (project-assistant) processing
  inventory (Task 9, AC-19/AC-20 "field-purpose and access inventory" owned
  surface).

  Holds one `ProjectAssistantProcessingRecord` per persisted field of every
  project-assistant schema. Field lists are read from each schema module's
  own `__schema__(:fields)` reflection rather than hand-copied, so
  `completeness/0` fails the moment a new column exists with no matching
  classification — the same mechanism `SddOrchestrator.Privacy.DeliveryProcessingInventory`
  established for specs/07.

  This is `design.md`'s `AssistantProcessingRecord` entity, realized as
  these classified records plus this task's local privacy and security
  review (recorded in `specs/12-project-assistant/progress.md`) rather than
  as a new persisted database table: design.md describes it as "the
  existing processing inventory and deployment privacy profile extended
  with assistant purposes, fields, access..." — extending the existing
  inventory pattern, not adding a new entity to store. There is nothing for
  a dedicated `AssistantProcessingRecord` table to hold that this module,
  `SddOrchestrator.Privacy.ProjectAssistantDataUsePolicy`, and
  `SddOrchestrator.Privacy.DeploymentPrivacyProfile` do not already
  represent as code — the same reasoning Tasks 4 and 5 used to conclude
  `RepositoryObservation` and `RepositorySourceIndex` need no migration.

  ## Classification reasoning

  - `basis` is `:contract_necessity` for every field: this feature
    processes conversation, turn, citation, and confirmation content only
    to answer the participant's own question and provide minimum service
    security (design.md's Business Rules). No inventoried field is an
    operational-security log; `SddOrchestrator.ProjectAssistant.SecurityLog`
    is deliberately separate, content-free, and non-persisted (Logger
    output under the deployment's own log retention), the same split
    `SddOrchestrator.AIRuntime.SecurityLog` already draws from
    `SddOrchestrator.Privacy.ProcessingInventory`.
  - `authority` matches each entity's real storage exactly, per Tasks 1, 2,
    3, and 7's own hosted/device pairing: `:both` for
    `ProjectAssistantConversation`, `ProjectAssistantTurn`,
    `ProjectAssistantCitation`, and `AssistantBoundaryConfirmation` (each
    has a hosted Ecto schema and a device delivery-seam pair);
    `ProjectContextProjection` is also `:both` (hosted Ecto schema plus
    `DeviceProjectContextProjection`).
  - `recipient_category` follows design.md's privacy boundary precisely:
    `ProjectAssistantConversation`, `ProjectAssistantTurn`,
    `ProjectAssistantCitation`, and `AssistantBoundaryConfirmation` are
    each visible only to `:owning_participant` — never
    `:current_participants`, the recipient category
    `DeliveryProcessingInventory` uses for shared feature data, because
    design.md is explicit that a conversation is narrower than project
    content access. `ProjectContextProjection` is the one exception: it
    holds no participant-private content of its own (only a derived cache
    of already project-shared metadata, specification identity, board
    state, run status, and evidence — content every current participant can
    already read through its own owning surface), so its recipient is
    `:current_participants`, matching that shared data's own existing
    access boundary rather than inventing a narrower one this projection
    does not actually enforce.
  - `question_text` and `answer_text` additionally carry `:model_provider`
    as their recipient and `:configured_model_provider` as their transfer
    classification: these two fields are the ones that actually cross to
    the participant's own configured personal AI connection as model input
    or model output (design.md's "Personal AI Connection With No Funded
    Fallback" decision — the participant's own provider, never an
    Orchestrator-funded one). Every other field stays `:no_transfer`:
    `context_version` is an opaque pointer, not source content;
    `uncertainty_markers`/`outcome`/`failure_reason` are the orchestrator's
    own normalized bookkeeping; citation `reference`/`excerpt` are already
    the minimized, redacted (specs/12 Task 9's own
    `SddOrchestrator.ProjectAssistant.SecretRedactor`) record of what a
    prior turn read, not new content being sent anywhere.
  - `lifecycle_owner` is `:specs_12_project_assistant_lifecycle` for every
    field without exception: this task (`SddOrchestrator.Privacy.Retention.prune_project_assistant_conversations/1`,
    `SddOrchestrator.ProjectAssistantStore.delete_conversation/3`,
    `SddOrchestrator.ProjectAssistant.DeviceConversationPurge`, and the
    hosted `on_delete: :delete_all` foreign keys Tasks 1, 2, 3, and 7 already
    declared) is the complete lifecycle authority for every project-assistant
    field; no other specification enforces any part of it.
  """

  alias SddOrchestrator.Privacy.ProjectAssistantProcessingRecord

  alias SddOrchestrator.ProjectAssistant.{
    AssistantBoundaryConfirmation,
    ProjectAssistantCitation,
    ProjectAssistantConversation,
    ProjectAssistantTurn,
    ProjectContextProjection
  }

  @schemas %{
    project_assistant_conversation: ProjectAssistantConversation,
    project_assistant_turn: ProjectAssistantTurn,
    project_assistant_citation: ProjectAssistantCitation,
    assistant_boundary_confirmation: AssistantBoundaryConfirmation,
    project_context_projection: ProjectContextProjection
  }

  @entity_defaults %{
    project_assistant_conversation: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :owning_participant,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_12_project_assistant_lifecycle
    ],
    project_assistant_turn: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :owning_participant,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_12_project_assistant_lifecycle
    ],
    project_assistant_citation: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :owning_participant,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_12_project_assistant_lifecycle
    ],
    assistant_boundary_confirmation: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :owning_participant,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_12_project_assistant_lifecycle
    ],
    project_context_projection: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_12_project_assistant_lifecycle
    ]
  }

  # Only `question_text` and `answer_text` cross to the configured personal
  # AI connection; every other field's default above already stands.
  @field_overrides %{
    project_assistant_turn: %{
      question_text: [
        recipient_category: :model_provider,
        transfer_classification: :configured_model_provider
      ],
      answer_text: [
        recipient_category: :model_provider,
        transfer_classification: :configured_model_provider
      ]
    }
  }

  @field_purposes %{
    project_assistant_conversation: %{
      id: "Preserve the stable identity of one private participant-project conversation.",
      last_activity_at:
        "Drive the 30-day maximum retention window from the conversation's own last activity.",
      project_id: "Bind the conversation to its owning project and deletion lifecycle.",
      account_id:
        "Bind the conversation to the one stable participant identity it is private to.",
      inserted_at: "Record conversation creation for lifecycle accountability.",
      updated_at: "Record the conversation's last touched-activity change for accountability."
    },
    project_assistant_turn: %{
      id: "Preserve the stable identity of one appended question-and-answer turn.",
      sequence: "Order a conversation's turns without gaps or rewrites.",
      question_text: "Hold the participant's own question, to ground and answer it.",
      answer_text: "Hold the composed, redacted answer returned to the participant.",
      context_version: "Bind the turn to the exact stored-context snapshot it was grounded on.",
      uncertainty_markers:
        "Record the visible partial, stale, excluded, unavailable, conflicting, or unstable markers shown beside the answer.",
      outcome: "Track whether the turn was answered, cancelled, or failed.",
      failure_reason:
        "Name a normalized reason when the turn failed, never a raw provider error.",
      conversation_id: "Bind the turn to the one private conversation it belongs to.",
      project_id: "Bind the turn to its owning project and deletion lifecycle.",
      inserted_at: "Record turn creation; a turn is appended once and never rewritten."
    },
    project_assistant_citation: %{
      id: "Preserve the stable identity of one authorization-checked citation.",
      source_type:
        "Classify the citation as a specification, repository, board, run, or evidence source.",
      reference:
        "Hold the exact typed identity the citation resolves to, never a full document body.",
      excerpt:
        "Hold the minimal cited excerpt only, redacted of detected secrets before storage.",
      turn_id: "Bind the citation to the one turn whose claim it supports.",
      project_id: "Bind the citation to its owning project and deletion lifecycle.",
      inserted_at:
        "Record citation creation; a citation is appended once, atomically with its turn."
    },
    assistant_boundary_confirmation: %{
      id: "Preserve the stable identity of one participant's disclosed-boundary confirmation.",
      boundary_digest:
        "Bind the confirmation to the exact disclosed processing boundary the participant reviewed.",
      boundary_version: "Record which version of the processing disclosure was confirmed.",
      confirmed_at: "Record when the participant confirmed the disclosed boundary.",
      project_id: "Bind the confirmation to the project whose boundary was disclosed.",
      account_id: "Bind the confirmation to the participant who gave it.",
      inserted_at: "Record confirmation creation for compliance accountability.",
      updated_at: "Record a re-confirmation after the disclosed boundary changed."
    },
    project_context_projection: %{
      id: "Preserve the stable identity of one project's stored-context projection.",
      context_version:
        "Detect a changed underlying snapshot so a turn never grounds on a stale projection.",
      content:
        "Hold the minimized current project metadata, specification identity, board, run, and evidence content already shared with every current participant.",
      refreshed_at: "Record when the projection was last rebuilt for lifecycle accountability.",
      project_id: "Bind the projection to its owning project and deletion lifecycle.",
      inserted_at: "Record projection creation for accountability.",
      updated_at: "Record a rebuild's replace-in-place update for accountability."
    }
  }

  @records (for {entity, purposes} <- @field_purposes,
                {field, purpose} <- purposes do
              defaults = Map.fetch!(@entity_defaults, entity)

              overrides =
                @field_overrides |> Map.get(entity, %{}) |> Map.get(field, [])

              attrs =
                defaults
                |> Keyword.merge(overrides)
                |> Keyword.merge(entity: entity, field: field, purpose: purpose)

              struct!(ProjectAssistantProcessingRecord, attrs)
            end)

  @doc "The specs/12 schema modules this inventory classifies."
  @spec schemas() :: %{atom() => module()}
  def schemas, do: @schemas

  @doc "One classified record per inventoried specs/12 field."
  @spec records() :: [ProjectAssistantProcessingRecord.t()]
  def records, do: @records

  @doc "The purpose map this inventory was built from, keyed by entity then field."
  @spec field_purposes() :: %{atom() => %{atom() => String.t()}}
  def field_purposes, do: @field_purposes

  @doc """
  Every schema field with no matching inventory entry, keyed by entity.

  Reads each schema module's own `__schema__(:fields)` reflection, so a
  field added to a specs/12 schema without a matching inventory entry is
  detected automatically. An entity with no missing fields is absent from
  the result.
  """
  @spec missing_fields() :: %{atom() => [atom()]}
  def missing_fields do
    for {entity, schema} <- @schemas,
        known = @field_purposes |> Map.get(entity, %{}) |> Map.keys() |> MapSet.new(),
        actual = schema.__schema__(:fields) |> MapSet.new(),
        missing = MapSet.difference(actual, known) |> Enum.sort(),
        missing != [],
        into: %{} do
      {entity, missing}
    end
  end

  @doc """
  Every inventory entry naming a field the schema no longer declares, keyed
  by entity. Catches a stale classification left behind by a removed
  column.
  """
  @spec unknown_fields() :: %{atom() => [atom()]}
  def unknown_fields do
    for {entity, schema} <- @schemas,
        known = @field_purposes |> Map.get(entity, %{}) |> Map.keys() |> MapSet.new(),
        actual = schema.__schema__(:fields) |> MapSet.new(),
        unknown = MapSet.difference(known, actual) |> Enum.sort(),
        unknown != [],
        into: %{} do
      {entity, unknown}
    end
  end

  @doc """
  Validates every record's classification and reports full field
  completeness (no unclassified field, no stale one).
  """
  @spec validate_all() :: :ok | {:error, [{ProjectAssistantProcessingRecord.t(), [atom()]}]}
  def validate_all do
    failures =
      for record <- records(),
          {:error, reasons} <- [ProjectAssistantProcessingRecord.validate(record)],
          do: {record, reasons}

    if failures == [], do: :ok, else: {:error, failures}
  end

  @doc "Reports `:ok` only when every schema field is classified and every classification is stale-free."
  @spec completeness() :: :ok | {:error, %{atom() => [atom()]}}
  def completeness do
    missing = missing_fields()
    unknown = unknown_fields()

    if missing == %{} and unknown == %{},
      do: :ok,
      else: {:error, Map.merge(missing, unknown, fn _entity, a, b -> Enum.uniq(a ++ b) end)}
  end
end
