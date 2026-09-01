defmodule SddOrchestrator.Privacy.DeliveryProcessingInventory do
  @moduledoc """
  The mechanically validated Slice 07 (guided-specification-delivery) processing
  inventory (specs/18 Task 1, AC-01).

  Holds one `DeliveryProcessingRecord` per persisted field of every guided-
  delivery schema, plus the `delivery.`-namespace usage of the shared
  account-level notification foundation
  (`SddOrchestrator.Notifications.AccountNotification`; see
  `SddOrchestrator.Delivery.NotificationAccess` for the namespace boundary that
  keeps Slice 08's `participation.` notifications out of this inventory).

  Field lists are read from each schema module's own `__schema__(:fields)`
  reflection rather than hand-copied, so `completeness/0` fails the moment a new
  Slice 07 column exists with no matching classification — that is what gives
  AC-01 ("no unclassified processing") its teeth.

  Every record's purpose, basis, authority, recipient, processor, transfer, and
  lifecycle-owner classification is mechanized from the approved Slice 07
  contract:

  - Basis is `:contract_necessity` for every inventoried field: guided delivery
    processes feature content, runs, evidence, previews, and reviews only to
    provide the participant-requested specification-delivery service. No
    inventoried field is an operational-security log (those already exist as
    `:operational_security_log` / `:ai_runtime_operational_log` in
    `SddOrchestrator.Privacy.ProcessingInventory`); `:operational_security`
    remains an approved basis value for a future Slice 07 security-log
    inventory to use.
  - Authority is `:both` for every entity whose context module commits through
    `SddOrchestrator.Delivery.DeliveryStore` or `ArtifactStore` (a hosted
    project persists it in PostgreSQL, a device-authoritative project persists
    it in the worker-owned device store, never both for the same row — see
    `DeliveryStore`'s and `ArtifactStore`'s moduledocs). `ReadinessAssessment`
    and `ProcessingDisclosure` commit directly through `SddOrchestrator.Repo`
    with no device adapter, so they are `:hosted`; so is the shared
    `AccountNotification` foundation.
  - Lifecycle owner points at the specification that owns removing the field,
    per the approved retention paragraph: `RunCommand` ("temporary command
    payloads") and a `BlockingQuestion`'s execution-recovery fields
    ("checkpoints") are inactive execution mechanics owned by
    specs/19 (`guided-delivery-operational-retention`, 30-day cleanup);
    `PreviewDeployment` and `EvidenceArtifact` are non-authoritative,
    already self-cleaning byte/observation stores also owned by specs/19;
    `Evidence.superseded_by_id` marks the one field that moves a row into that
    same specs/19 cleanup once set; the `delivery.` notification fields are
    already governed by the implemented specs/17
    (`guided-delivery-notification-access`, 90-day retention); everything else
    — active feature history, run and attempt metadata, normalized activity,
    accepted evidence, reviews, and the start-time processing confirmation — is
    retained while the project is active and removed only by project deletion,
    owned by specs/21 (`guided-delivery-deletion-and-recovery`).
    specs/20 (`guided-delivery-device-data-retention`) owns the hosted relay's
    own transient copies for a device-authoritative project, not the
    authoritative rows classified here, so no field below names it; it remains
    an approved lifecycle-owner value.

  Retention *enforcement* is out of this task's scope by design: a
  `lifecycle_owner` here is a pointer to the specification responsible for
  enforcing it, not the enforcement itself.
  """

  alias SddOrchestrator.Privacy.DeliveryProcessingRecord

  @schemas %{
    feature: SddOrchestrator.Delivery.Feature,
    readiness_assessment: SddOrchestrator.Delivery.ReadinessAssessment,
    agent_run: SddOrchestrator.Delivery.AgentRun,
    run_attempt: SddOrchestrator.Delivery.RunAttempt,
    run_command: SddOrchestrator.Delivery.RunCommand,
    blocking_question: SddOrchestrator.Delivery.BlockingQuestion,
    activity_entry: SddOrchestrator.Delivery.ActivityEntry,
    evidence: SddOrchestrator.Delivery.Evidence,
    evidence_artifact: SddOrchestrator.Delivery.EvidenceArtifact,
    preview_deployment: SddOrchestrator.Delivery.PreviewDeployment,
    review_decision: SddOrchestrator.Delivery.ReviewDecision,
    processing_confirmation: SddOrchestrator.Delivery.ProcessingDisclosure,
    account_notification: SddOrchestrator.Notifications.AccountNotification
  }

  @entity_defaults %{
    feature: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    readiness_assessment: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    agent_run: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    run_attempt: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    run_command: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :worker_or_provider_capability,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :hosted_relay_transient,
      lifecycle_owner: :specs_19_operational_retention
    ],
    blocking_question: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_19_operational_retention
    ],
    activity_entry: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    evidence: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    evidence_artifact: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_19_operational_retention
    ],
    preview_deployment: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_19_operational_retention
    ],
    review_decision: [
      authority: :both,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database_or_device_worker,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    processing_confirmation: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :operations_support,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_21_deletion_and_recovery
    ],
    account_notification: [
      authority: :hosted,
      basis: :contract_necessity,
      recipient_category: :current_participants,
      processor_category: :hosted_database,
      transfer_classification: :no_transfer,
      lifecycle_owner: :specs_17_notification_access
    ]
  }

  # Fields whose role differs from their entity's default classification.
  # `run_attempt`'s lease fields are execution-concurrency machinery read by
  # the dispatcher, not shown to a participant, and expire with the attempt
  # rather than being retained as run/attempt metadata. `blocking_question`'s
  # checkpoint/branch/workspace_path are the opaque resume aid a worker reads
  # to continue accepted work; the human-readable question and its answer are
  # duplicated into `activity_entry` as the retained authoritative history.
  # `evidence.superseded_by_id` is the one field whose presence moves a row
  # into specs/19's superseded-artifact cleanup. `preview_deployment`'s
  # provider fields are the configured remote preview capability the approved
  # contract requires to appear in the confirmed start disclosure.
  @field_overrides %{
    run_attempt: %{
      lease_owner: [
        recipient_category: :worker_or_provider_capability,
        lifecycle_owner: :specs_19_operational_retention
      ],
      lease_expires_at: [
        recipient_category: :worker_or_provider_capability,
        lifecycle_owner: :specs_19_operational_retention
      ],
      fence_token: [
        recipient_category: :worker_or_provider_capability,
        lifecycle_owner: :specs_19_operational_retention
      ]
    },
    blocking_question: %{
      checkpoint: [recipient_category: :worker_or_provider_capability],
      branch: [recipient_category: :worker_or_provider_capability],
      workspace_path: [recipient_category: :worker_or_provider_capability]
    },
    evidence: %{
      superseded_by_id: [lifecycle_owner: :specs_19_operational_retention]
    },
    preview_deployment: %{
      provider: [
        processor_category: :preview_provider,
        transfer_classification: :configured_remote_capability
      ],
      provider_ref: [
        processor_category: :preview_provider,
        transfer_classification: :configured_remote_capability
      ],
      link: [
        processor_category: :preview_provider,
        transfer_classification: :configured_remote_capability
      ],
      path: [
        processor_category: :preview_provider,
        transfer_classification: :configured_remote_capability
      ]
    }
  }

  @field_purposes %{
    feature: %{
      id: "Preserve the stable project-scoped identity of one delivery feature.",
      title: "Present the user-facing feature label shown on the delivery board.",
      lifecycle_column: "Drive the feature's board column through only its legal transitions.",
      status: "Surface a blocking or failed status while the feature is in development.",
      state_version:
        "Enforce optimistic concurrency so a stale client cannot overwrite a moved card.",
      specification_id: "Link the feature to the specification the run works from.",
      project_id: "Bind the feature to its owning project and deletion lifecycle.",
      creator_account_id: "Attribute the feature to the participant who created it.",
      assigned_account_id: "Record the optional participant currently assigned to the feature.",
      inserted_at: "Record feature creation for lifecycle accountability.",
      updated_at:
        "Record the feature's last column, status, or assignment change for accountability."
    },
    readiness_assessment: %{
      id: "Preserve the stable identity of one readiness verdict.",
      specification_id: "Bind the verdict to the specification it judged.",
      revision_id: "Bind the verdict to the exact specification revision it judged.",
      revision_digest: "Detect a moved revision so a stale verdict is never read as current.",
      findings: "Hold the visible blocking findings and suggestions the verdict produced.",
      guidance:
        "Record whether a guidance model judged this verdict, so the page can say the findings are structural only.",
      dismissed_ids: "Record which non-blocking suggestions the participant has dismissed.",
      version: "Enforce optimistic concurrency on dismissal against a superseded finding list.",
      assessed_at: "Record when the verdict was produced for lifecycle accountability.",
      project_id: "Bind the readiness verdict to its owning project and deletion lifecycle.",
      feature_id: "Bind the verdict to the one feature it judged.",
      inserted_at: "Record verdict creation for lifecycle accountability.",
      updated_at: "Record a new verdict or dismissal for accountability."
    },
    agent_run: %{
      id: "Preserve the stable identity of one authorized delivery run.",
      starting_revision_id:
        "Bind the run to the immutable specification revision it started from.",
      starting_revision_digest: "Detect drift between the recorded and actual starting revision.",
      effective_revision_id:
        "Track the specification revision the run is currently working from.",
      effective_revision_digest:
        "Detect drift between the recorded and actual effective revision.",
      approved_slice:
        "Record the approved implementation slice the run is authorized to deliver.",
      branch: "Record the one isolated branch this run owns for its whole lifetime.",
      state:
        "Track the run through its pending/running/blocked/failed/canceled/completed lifecycle.",
      failure_reason: "Name the reason a failed run stopped.",
      current_attempt_number: "Point at the run's current ordered execution attempt.",
      state_version: "Enforce optimistic concurrency on run state transitions.",
      project_id: "Bind the run to its owning project and deletion lifecycle.",
      feature_id: "Bind the run to the one feature it delivers.",
      initiator_account_id: "Attribute the run to the participant who started it.",
      inserted_at: "Record run creation for lifecycle accountability.",
      updated_at: "Record the run's last state or revision change for accountability."
    },
    run_attempt: %{
      id: "Preserve the stable identity of one exclusive execution attempt.",
      attempt_number: "Order attempts of the same run without reusing a number.",
      state: "Track the attempt through its pending/dispatched/running/terminal lifecycle.",
      continuation_reason:
        "Record why this attempt continues the run (retry, resume, rejection).",
      effective_revision_id: "Bind the attempt to the exact specification revision it executes.",
      effective_revision_digest: "Detect drift between the recorded and actual attempt revision.",
      manifest_digest: "Bind the attempt to its immutable execution manifest.",
      required_checks: "Snapshot the required-check contract the attempt started under.",
      lease_owner: "Identify the worker currently holding this attempt's execution lease.",
      lease_expires_at: "Bound how long a claimed execution lease remains valid.",
      fence_token:
        "Reject a superseded worker's late events even if it still believes it holds the lease.",
      last_sequence: "Reject a duplicated or out-of-order worker event.",
      state_version: "Enforce optimistic concurrency on attempt state transitions.",
      run_id: "Bind the attempt to the one run it belongs to.",
      inserted_at: "Record attempt creation for lifecycle accountability.",
      updated_at: "Record the attempt's last state or sequence change for accountability."
    },
    run_command: %{
      id: "Preserve the caller-supplied idempotent identity of one durable instruction.",
      operation: "Name the start/resume/retry/cancel/reconcile instruction being delivered.",
      expected_state_version:
        "Refuse to apply an instruction against a run state that has moved.",
      manifest_digest: "Bind an execution instruction to the manifest it must run.",
      due_at: "Schedule when the instruction becomes eligible for dispatch.",
      state:
        "Track the instruction through its pending/claimed/delivered/acknowledged/failed lifecycle.",
      claimed_by: "Identify which dispatcher currently owns delivering this instruction.",
      claim_expires_at: "Bound how long a dispatcher's claim remains valid.",
      delivery_count: "Record how many times an at-least-once instruction has been delivered.",
      delivered_at: "Record when the instruction was last delivered.",
      acknowledged_at: "Record when the worker confirmed the instruction.",
      result:
        "Hold the worker's acknowledgement result so a redelivery replays it instead of repeating work.",
      failure_code: "Name a short terminal delivery-failure reason.",
      project_id: "Bind the instruction to its owning project and deletion lifecycle.",
      run_id: "Bind the instruction to the run it acts on.",
      attempt_id: "Bind the instruction to the attempt it acts on, when it targets one.",
      inserted_at: "Record instruction creation for lifecycle accountability.",
      updated_at:
        "Record the instruction's last delivery or acknowledgement change for accountability."
    },
    blocking_question: %{
      id: "Preserve the stable identity of one blocking question.",
      question: "Record the focused product decision a responder must answer.",
      context: "Give the responder the information needed to decide.",
      state: "Track the question through open/answered/superseded.",
      checkpoint: "Hold the opaque worker state needed to resume accepted work after an answer.",
      branch: "Record the run's branch the question was raised against.",
      workspace_path: "Record the worker-local workspace the question was raised from.",
      asked_at: "Record when the question was raised for lifecycle accountability.",
      resulting_revision_id:
        "Bind an answered question to the specification revision the answer produced.",
      state_version: "Enforce optimistic concurrency on question resolution.",
      project_id: "Bind the question to its owning project and deletion lifecycle.",
      feature_id: "Bind the question to the feature it pauses.",
      run_id: "Bind the question to the run it pauses.",
      attempt_id: "Bind the question to the attempt that raised it.",
      inserted_at: "Record question creation for lifecycle accountability.",
      updated_at: "Record the question's resolution for accountability."
    },
    activity_entry: %{
      id: "Preserve the stable identity of one immutable activity record.",
      actor_kind: "Say whether the entry was produced by a participant, an agent, or the system.",
      type: "Classify the normalized kind of progress, comment, question, answer, or outcome.",
      sequence: "Order the feature's authoritative activity history without gaps or rewrites.",
      occurred_at: "Record when the activity happened for lifecycle accountability.",
      payload:
        "Hold the minimized normalized detail of the activity, with raw streams and credentials rejected on write.",
      project_id: "Bind the entry to its owning project and deletion lifecycle.",
      feature_id: "Bind the entry to the feature whose history it belongs to.",
      run_id: "Bind the entry to the run it reports on, when it reports on one.",
      attempt_id: "Bind the entry to the attempt it reports on, when it reports on one.",
      actor_account_id: "Attribute a participant-authored entry to the account that authored it.",
      inserted_at: "Record entry append time; the entry itself is never updated."
    },
    evidence: %{
      id: "Preserve the stable identity of one item of proof.",
      command_id: "Correlate the evidence to the worker command that produced it.",
      kind: "Classify the evidence as a required check, screenshot, or preview result.",
      name: "Name the specific check or artifact the evidence proves.",
      outcome: "Record whether the proof passed, failed, or was missing or unsupported.",
      command: "Record the exact command that was run, so a reader can verify the claim.",
      exit_code: "Record the command's exit code as objective proof of outcome.",
      duration_ms: "Record how long the proof took to run.",
      branch: "Record the run's branch the evidence was produced on.",
      commit_sha: "Record the exact commit the evidence proves.",
      source:
        "Record whether the check runner or the worker produced the evidence; never the agent's own narrative.",
      recorded_at: "Record when the proof was captured for lifecycle accountability.",
      digest: "Address the evidence's artifact bytes without storing them inline.",
      redacted: "Flag that the associated artifact content is withheld from ordinary display.",
      artifact_ref:
        "Point at the private artifact store entry for this evidence's bytes, when one exists.",
      state_version: "Enforce optimistic concurrency on the one legal write (supersession).",
      project_id: "Bind the evidence to its owning project and deletion lifecycle.",
      feature_id: "Bind the evidence to the feature it proves work for.",
      run_id: "Bind the evidence to the run it was produced under.",
      attempt_id: "Bind the evidence to the attempt it was produced under.",
      superseded_by_id:
        "Mark evidence replaced by a rerun or later disagreement, without rewriting the original row.",
      inserted_at: "Record evidence capture time; the row is never otherwise updated."
    },
    evidence_artifact: %{
      id: "Preserve the stable identity of one stored artifact.",
      digest: "Address the artifact by the verified hash of its own content.",
      content_type: "Record the artifact's approved content type for safe rendering.",
      byte_size: "Record the artifact's size against the approved size ceiling.",
      redacted: "Flag that the artifact's bytes are withheld from ordinary display.",
      content:
        "Hold the encrypted-at-rest artifact bytes, exposed only through the authorized redaction-safe presentation path; never a raw URL or a captured credential.",
      project_id: "Bind the artifact to its owning project and deletion lifecycle.",
      inserted_at: "Record artifact storage time; the row is never otherwise updated."
    },
    preview_deployment: %{
      id: "Preserve the stable identity of one requested preview.",
      branch: "Record the run's branch the preview deploys.",
      commit_sha: "Bind the preview to the exact commit the attempt verified.",
      path: "Record the configurable preview path requested.",
      provider: "Name the configured non-production deployment provider.",
      provider_ref:
        "Address the deployment at the provider with an opaque handle; never a usable link.",
      link: "Hold the one participant-safe preview link, once the deployment is ready.",
      status: "Track the preview through pending/ready/failed/timed_out/expired/superseded.",
      failure_reason: "Name a machine-readable reason the preview stopped.",
      requested_at: "Record when the preview was requested for lifecycle accountability.",
      ready_at: "Record when the preview became reachable.",
      timeout_at: "Bound how long a pending preview may remain unresolved.",
      expires_at: "Record when a ready preview is expected to stop being reachable.",
      cleanup_state:
        "Track whether provider-side cleanup of this preview is owed, requested, or done.",
      cleanup_command_id:
        "Correlate the preview to the durable cleanup instruction that removes it.",
      state_version: "Enforce optimistic concurrency on preview observation and supersession.",
      project_id: "Bind the preview to its owning project and deletion lifecycle.",
      feature_id: "Bind the preview to the feature it demonstrates.",
      run_id: "Bind the preview to the run it was requested for.",
      attempt_id: "Bind the preview to the exact attempt whose commit it deploys.",
      superseded_by_id:
        "Mark a preview replaced by a later attempt's deployment, without rewriting the original row.",
      inserted_at: "Record preview request time for lifecycle accountability.",
      updated_at:
        "Record the preview's last observed status or cleanup change for accountability."
    },
    review_decision: %{
      id: "Preserve the stable identity of one final review verdict.",
      decision: "Record the approval or rejection outcome.",
      feedback: "Hold the reviewer's feedback that a rejection requires and an approval forbids.",
      branch: "Record the exact branch the verdict was decided against.",
      commit_sha: "Record the exact commit the verdict was decided against.",
      decided_at: "Record when the verdict was made for lifecycle accountability.",
      state_version: "Enforce optimistic concurrency; the row otherwise accepts no update.",
      preview_deployment_id:
        "Point at the preview the reviewer could have opened; a convenience reference only.",
      project_id: "Bind the verdict to its owning project and deletion lifecycle.",
      feature_id: "Bind the verdict to the feature it decides.",
      run_id: "Bind the verdict to the run it decides.",
      attempt_id: "Bind the verdict to the one attempt it decides, exactly once.",
      reviewer_account_id:
        "Attribute the verdict to the reviewing participant, by reference, never by email.",
      inserted_at: "Record verdict creation time; the row is never otherwise updated.",
      updated_at:
        "Present for schema consistency; a review decision is never updated after creation."
    },
    processing_confirmation: %{
      id: "Preserve the stable identity of one participant's start-time confirmation.",
      disclosure_version:
        "Record which version of the processing-boundary disclosure was confirmed.",
      disclosure_digest:
        "Bind the confirmation to the exact disclosed boundary the participant reviewed.",
      confirmed_at: "Record when the participant confirmed the disclosed boundary.",
      project_id: "Bind the confirmation to the project whose boundary was disclosed.",
      account_id: "Bind the confirmation to the participant who gave it.",
      inserted_at: "Record confirmation creation for compliance accountability.",
      updated_at: "Record a re-confirmation after the disclosed boundary changed."
    },
    account_notification: %{
      id: "Preserve the stable identity of one guided-delivery notification.",
      event_type:
        "Classify the delivery.* event this notification reports, from the approved vocabulary.",
      subject_ref:
        "Address the delivery subject (run, question, review) the notification is about.",
      event_version: "Distinguish a redelivered or updated event from the same subject.",
      title: "Present the short user-facing notification title.",
      body: "Present the short minimized user-facing notification body.",
      project_label: "Show the project display label without a second copy of project content.",
      actor_label: "Show the acting participant's display label without their email.",
      link_path:
        "Route the participant to the authorized in-product screen; never an absolute or external URL.",
      occurred_at: "Record when the underlying delivery event happened.",
      read_at: "Track the notification's read state for the recipient.",
      account_id: "Bind the notification to the recipient account and its deletion lifecycle.",
      inserted_at: "Record notification creation for the 90-day retention window.",
      updated_at: "Record the notification's last read-state change for accountability."
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

              struct!(DeliveryProcessingRecord, attrs)
            end)

  @doc "The Slice 07 (and delivery-namespace Slice 08 foundation) schema modules this inventory classifies."
  @spec schemas() :: %{atom() => module()}
  def schemas, do: @schemas

  @doc "One classified record per inventoried Slice 07 field or transfer."
  @spec records() :: [DeliveryProcessingRecord.t()]
  def records, do: @records

  @doc "The purpose map this inventory was built from, keyed by entity then field."
  @spec field_purposes() :: %{atom() => %{atom() => String.t()}}
  def field_purposes, do: @field_purposes

  @doc """
  Every schema field with no matching inventory entry, keyed by entity.

  Reads each schema module's own `__schema__(:fields)` reflection, so a field
  added to a Slice 07 schema without a matching inventory entry is detected
  automatically rather than by keeping a second hand-written field list in
  sync. An entity with no missing fields is absent from the result.
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
  Every inventory entry naming a field the schema no longer declares, keyed by
  entity. Catches a stale classification left behind by a removed column.
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
  Validates every record's classification.

  Returns `:ok` when every record names an approved purpose, basis, authority,
  recipient, processor, transfer, and lifecycle owner; otherwise
  `{:error, [{record, reasons}, ...]}` for every record that failed, so a
  caller sees every defect rather than only the first.
  """
  @spec validate_all() :: :ok | {:error, [{DeliveryProcessingRecord.t(), [atom()]}]}
  def validate_all do
    failures =
      for record <- records(),
          {:error, reasons} <- [DeliveryProcessingRecord.validate(record)],
          do: {record, reasons}

    if failures == [], do: :ok, else: {:error, failures}
  end
end
