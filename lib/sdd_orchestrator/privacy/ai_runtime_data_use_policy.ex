defmodule SddOrchestrator.Privacy.AIRuntimeDataUsePolicy do
  @moduledoc """
  Fail-closed purpose and recipient boundary for AI-runtime governance data.

  This policy covers the control-plane records owned by Slice 11: the minimized
  personal connection reference, the short-lived catalog and allowance
  projections, the pinned runtime configuration, its spending-ceiling ledger,
  the agent runtime observations, and the content-free operational log.

  Least privilege is expressed in the map itself rather than in prose. Across
  the six record classes, `:approved_operations` appears only under
  `:retention_cleanup` and `:verified_rights_operator` only under
  `:verified_rights`: support and operations personnel are given a lifecycle
  and rights route, never a content-reading one. `:participant_run_visibility`
  exists only for the pinned session and the observations, and only for a
  current authorized project participant, because a participant may see the run
  they take part in but never the account-wide allowance, credits, or spend.
  `:credential_locality` belongs to the connection alone and only to the
  authorized worker, because credential handling stays on the user's device.

  `:model_provider` is a prohibited consumer here even though the user's runs do
  reach a provider. The provider is contacted only by the user's own
  worker-local official client, for the work the user asked for. These
  control-plane governance records are a separate thing: they are never sent to
  the provider, and none of them may become training or product-improvement
  input for anyone.
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
    :coding_agent,
    :model_provider
  ]

  @allowed %{
    personal_ai_connection: %{
      connection_selection: [:connection_owner],
      credential_locality: [:authorized_worker],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    ai_model_catalog: %{
      catalog_selection: [
        :connection_owner,
        :authorized_worker,
        :support_assistant_runtime,
        :working_agent_runtime
      ],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    ai_quota_snapshot: %{
      quota_control: [
        :connection_owner,
        :authorized_worker,
        :support_assistant_runtime,
        :working_agent_runtime
      ],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    ai_runtime_session: %{
      runtime_pinning: [
        :connection_owner,
        :support_assistant_runtime,
        :working_agent_runtime
      ],
      participant_run_visibility: [:current_project_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    ai_runtime_cost_ledger: %{
      spending_control: [
        :connection_owner,
        :support_assistant_runtime,
        :working_agent_runtime
      ],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    agent_runtime_observation: %{
      operational_observation: [:connection_owner, :working_agent_runtime],
      participant_run_visibility: [:current_project_participant],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    ai_runtime_operational_log: %{
      security_operations: [:approved_operations],
      reliability_operations: [:approved_operations],
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
      :connection,
      :worker_profile,
      :session,
      :consumer,
      :content,
      :network,
      :stable_pseudonymous_identifier
    ]
  }

  @type data_class ::
          :personal_ai_connection
          | :ai_model_catalog
          | :ai_quota_snapshot
          | :ai_runtime_session
          | :ai_runtime_cost_ledger
          | :agent_runtime_observation
          | :ai_runtime_operational_log

  @doc "Authorizes only an explicitly approved AI-runtime purpose and recipient."
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

  @doc "The AI-runtime data classes governed by the fail-closed boundary."
  @spec data_classes() :: [data_class()]
  def data_classes, do: Map.keys(@allowed)

  @doc "The approved purpose-to-consumer routes, keyed by data class."
  @spec allowed_routes() :: %{data_class() => %{atom() => [atom()]}}
  def allowed_routes, do: @allowed

  @doc "The secondary-use purposes refused for every AI-runtime data class."
  @spec prohibited_purposes() :: [atom()]
  def prohibited_purposes, do: @prohibited_purposes

  @doc "The recipients refused for every AI-runtime data class and purpose."
  @spec prohibited_consumers() :: [atom()]
  def prohibited_consumers, do: @prohibited_consumers
end
