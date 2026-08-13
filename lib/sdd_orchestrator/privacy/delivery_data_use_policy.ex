defmodule SddOrchestrator.Privacy.DeliveryDataUsePolicy do
  @moduledoc """
  Fail-closed purpose and recipient boundary for Slice 07 guided-delivery data
  (specs/18 Task 4, AC-05).

  This policy covers the thirteen entities classified field-by-field in
  `SddOrchestrator.Privacy.DeliveryProcessingInventory` (Task 1): a feature's
  board state, its readiness verdicts, an authorized run and its attempts, the
  durable dispatch instructions that drive a worker, a blocking question, the
  normalized activity history, accepted evidence and its stored bytes, a
  requested preview, a final review decision, the start-time processing
  confirmation, and the delivery-namespace account notification.

  Unlike `SddOrchestrator.Privacy.AIRuntimeDataUsePolicy`, which blanket-
  prohibits `:model_provider` because its governed records are control-plane
  governance data that never legitimately reaches a provider, guided delivery
  is different: a run's execution manifest is *for* the worker and, through
  it, the model that executes the work, and a preview is *for* the configured
  preview provider that hosts it. Prohibiting `:model_provider` and
  `:preview_provider` outright would misclassify the product's own delivery
  mechanism as a privacy violation. Instead, both are ordinary consumers that
  are legitimate only through the `@allowed` map's narrow `:worker_dispatch`
  and `:preview_deployment` routes, and refused everywhere else — including
  for any secondary-use purpose — by the same fail-closed purpose check every
  other consumer is subject to. `authorize/3` checks the purpose before the
  consumer is even inspected, so `:model_provider` and `:preview_provider` are
  refused for `:advertising` or `:model_training` exactly like any other
  consumer, never treated as pre-approved.

  Purposes here are deliberately coarser than Task 1's nine-field
  classification: Task 1 answers "what is this field's classification,"
  this module answers "is this purpose/recipient pair ever legitimate,"
  regardless of which field carries it. `:feature_delivery` covers the
  participant-facing board, verdict, run, activity, evidence, and review
  content; `:worker_dispatch` covers the durable instructions and lease state
  that drive a worker (and, for `run_command`, the model it dispatches to);
  `:preview_deployment` covers the one configured remote preview capability;
  `:notification_delivery` covers the delivery-namespace account
  notification; `:compliance_evidence` covers the start-time processing
  confirmation, which Task 1 classifies as operations-support evidence, never
  a participant-facing record; `:retention_cleanup` and `:verified_rights`
  are the lifecycle and rights routes every entity carries.
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
    :unrelated_processor
  ]

  @allowed %{
    feature: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    readiness_assessment: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    agent_run: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    run_attempt: %{
      feature_delivery: [:current_participant],
      worker_dispatch: [:worker_runtime],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    run_command: %{
      worker_dispatch: [:worker_runtime, :model_provider],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    blocking_question: %{
      feature_delivery: [:current_participant],
      worker_dispatch: [:worker_runtime],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    activity_entry: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    evidence: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    evidence_artifact: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    preview_deployment: %{
      feature_delivery: [:current_participant],
      preview_deployment: [:preview_provider],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    review_decision: %{
      feature_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    processing_confirmation: %{
      compliance_evidence: [:approved_operations],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    account_notification: %{
      notification_delivery: [:current_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    }
  }

  @anonymous_aggregate_boundary %{
    current_processing: :prohibited,
    future_requirement: :aggregate_and_genuinely_anonymous,
    prohibited_identifiers: [
      :user,
      :account,
      :project,
      :feature,
      :run,
      :repository,
      :worker,
      :provider,
      :device,
      :content,
      :network,
      :stable_pseudonymous_identifier
    ]
  }

  @type data_class ::
          :feature
          | :readiness_assessment
          | :agent_run
          | :run_attempt
          | :run_command
          | :blocking_question
          | :activity_entry
          | :evidence
          | :evidence_artifact
          | :preview_deployment
          | :review_decision
          | :processing_confirmation
          | :account_notification

  @doc "Authorizes only an explicitly approved guided-delivery purpose and recipient."
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

  @doc "The guided-delivery data classes governed by the fail-closed boundary."
  @spec data_classes() :: [data_class()]
  def data_classes, do: Map.keys(@allowed)

  @doc "The approved purpose-to-consumer routes, keyed by data class."
  @spec allowed_routes() :: %{data_class() => %{atom() => [atom()]}}
  def allowed_routes, do: @allowed

  @doc "The secondary-use purposes refused for every guided-delivery data class."
  @spec prohibited_purposes() :: [atom()]
  def prohibited_purposes, do: @prohibited_purposes

  @doc "The recipients refused for every guided-delivery data class and purpose."
  @spec prohibited_consumers() :: [atom()]
  def prohibited_consumers, do: @prohibited_consumers
end
