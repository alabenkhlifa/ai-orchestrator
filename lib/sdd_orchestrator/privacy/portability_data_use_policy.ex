defmodule SddOrchestrator.Privacy.PortabilityDataUsePolicy do
  @moduledoc """
  Fail-closed purpose and recipient boundary for portability operation data.

  This policy covers the package and temporary restoration boundary owned by
  Slice 06. Once a restore commits, the resulting authoritative project records
  remain governed by their own approved project and specification workflows.
  """

  @prohibited_purposes [
    :analytics,
    :advertising,
    :identity_tracking,
    :model_training,
    :unrelated_product_improvement
  ]

  @prohibited_consumers [:coding_agent, :model_provider]

  @allowed %{
    project_package: %{
      backup_generation: [:authorized_user, :selected_destination],
      backup_delivery: [:authorized_user],
      restore_validation: [:selected_destination],
      restore_commit: [:selected_destination]
    },
    import_attempt: %{
      restore_intake: [:authorized_user, :selected_destination],
      restore_validation: [:selected_destination],
      retention_cleanup: [:approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    restore_operation: %{
      restore_validation: [:selected_destination],
      restore_commit: [:selected_destination]
    },
    package_provenance: %{
      compatibility: [:authorized_project],
      project_lifecycle: [:authorized_project, :approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    hosted_local_repository_binding: %{
      repository_routing: [:authorized_project, :authorized_device_worker],
      authorization_validation: [:authorized_project, :authorized_device_worker],
      project_lifecycle: [:authorized_project, :approved_operations],
      verified_rights: [:verified_rights_operator]
    },
    operational_security_log: %{
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
      :repository,
      :package,
      :content,
      :network,
      :stable_pseudonymous_identifier
    ]
  }

  @type data_class ::
          :project_package
          | :import_attempt
          | :restore_operation
          | :package_provenance
          | :hosted_local_repository_binding
          | :operational_security_log

  @doc "Authorizes only an explicitly approved portability purpose and recipient."
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

  @doc "The portability data classes governed by the fail-closed boundary."
  @spec data_classes() :: [data_class()]
  def data_classes, do: Map.keys(@allowed)
end
