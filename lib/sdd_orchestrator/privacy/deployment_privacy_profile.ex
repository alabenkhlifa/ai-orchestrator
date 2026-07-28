defmodule SddOrchestrator.Privacy.DeploymentPrivacyProfile do
  @moduledoc """
  Deployment-specific privacy release evidence and its release gate.

  The stable implementation contract is approved (see `ProcessingInventory`), but a
  public hosted deployment must additionally record the controller identity and
  contact, processor list, hosting and backup regions, cross-border transfer
  safeguards, privacy notice, incident path, retention enforcement, completed
  reviews, and the passwordless delivery, retention, transfer, and review evidence.
  A profile missing any of these blocks release — and only release: it does not
  block implementation or local verification, so this gate is a separate, explicit
  readiness check rather than part of `mix release`.
  """
  @required [
    :controller_contact,
    :processors,
    :hosting_regions,
    :transfer_safeguards,
    :privacy_notice,
    :incident_path,
    :retention_enforcement,
    :reviews,
    :encrypted_backup_configuration,
    :passwordless_delivery_provider,
    :passwordless_processor_agreement,
    :passwordless_sender_domain,
    :passwordless_provider_region,
    :passwordless_transfer_safeguards,
    :passwordless_retention_approval,
    :passwordless_privacy_review,
    :passwordless_anonymisation_confirmation
  ]

  defstruct Enum.map(@required, &{&1, nil})

  @type t :: %__MODULE__{}

  @retention_requirements %{
    operational_security_logs_days: 30,
    encrypted_rolling_backups_days: 35
  }

  @backup_evidence_fields [
    :processor,
    :processor_agreement,
    :regions,
    :transfer_safeguards,
    :retention_enforcement,
    :recovery_authorization,
    :privacy_review
  ]

  @backup_lifecycle_contract %{
    encrypted: true,
    maximum_expiry_days: @retention_requirements.encrypted_rolling_backups_days,
    restore_scope: :approved_recovery_only,
    deletion_propagation: :required,
    enforcement: :deployment_infrastructure,
    evidence_stage: :release
  }

  @doc "The deployment evidence fields required before a public hosted release."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required

  @doc "Infrastructure-enforced expiry ceilings required by the privacy release gate."
  @spec retention_requirements() :: %{
          operational_security_logs_days: pos_integer(),
          encrypted_rolling_backups_days: pos_integer()
        }
  def retention_requirements, do: @retention_requirements

  @doc "The fixed encrypted-backup lifecycle that every deployment must enforce."
  @spec backup_lifecycle_contract() :: %{
          encrypted: true,
          maximum_expiry_days: pos_integer(),
          restore_scope: :approved_recovery_only,
          deletion_propagation: :required,
          enforcement: :deployment_infrastructure,
          evidence_stage: :release
        }
  def backup_lifecycle_contract, do: @backup_lifecycle_contract

  @doc "The lifecycle handoff attached to a verified rights action."
  @spec backup_handoff(:access | :erasure | :apply_operator_decision) :: %{
          action: :access | :erasure | :apply_operator_decision,
          maximum_expiry_days: pos_integer(),
          restore_scope: :approved_recovery_only,
          deletion_propagation: :required
        }
  def backup_handoff(action)
      when action in [:access, :erasure, :apply_operator_decision] do
    @backup_lifecycle_contract
    |> Map.take([:deletion_propagation, :maximum_expiry_days, :restore_scope])
    |> Map.put(:action, action)
  end

  @doc "Builds a profile from a map of provided evidence."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, Map.take(attrs, @required))
  end

  @doc "The required evidence fields that are still missing (blank or nil)."
  @spec missing_requirements(t()) :: [atom()]
  def missing_requirements(%__MODULE__{} = profile) do
    Enum.filter(@required, fn field -> blank?(Map.get(profile, field)) end)
  end

  @doc "Whether the profile records every required piece of deployment evidence."
  @spec release_ready?(t()) :: boolean()
  def release_ready?(%__MODULE__{} = profile), do: missing_requirements(profile) == []

  @doc """
  The release-gate assertion: `:ok` when complete, or `{:error, {:incomplete, missing}}`
  naming the missing evidence. Blocks release only; implementation and local
  verification proceed regardless.
  """
  @spec ensure_release_ready(t()) :: :ok | {:error, {:incomplete, [atom()]}}
  def ensure_release_ready(%__MODULE__{} = profile) do
    case missing_requirements(profile) do
      [] -> :ok
      missing -> {:error, {:incomplete, missing}}
    end
  end

  @doc """
  Checks the deployment's encrypted-backup processor and lifecycle evidence.

  The configuration may shorten the fixed 35-day ceiling, but it cannot weaken
  encryption, recovery authorization, or deletion propagation. Missing
  deployment evidence blocks release only.
  """
  @spec ensure_backup_release_ready(t()) ::
          :ok
          | {:error, {:incomplete, [atom()]}}
          | {:error, {:invalid_backup_configuration, [atom()]}}
  def ensure_backup_release_ready(%__MODULE__{} = profile) do
    with :ok <- ensure_release_ready(profile),
         [] <- invalid_backup_fields(profile.encrypted_backup_configuration) do
      :ok
    else
      {:error, {:incomplete, _missing}} = error ->
        error

      invalid when is_list(invalid) ->
        {:error, {:invalid_backup_configuration, invalid}}
    end
  end

  @doc """
  Enforces both deployment evidence and a production-capable passwordless
  delivery configuration.
  """
  @spec ensure_passwordless_release_ready(t(), map()) ::
          :ok
          | {:error, {:incomplete, [atom()]}}
          | {:error, {:unsafe_delivery_configuration, atom()}}
  def ensure_passwordless_release_ready(
        %__MODULE__{} = profile,
        delivery_configuration \\ SddOrchestrator.HostedAccess.DeliveryConfiguration.current()
      ) do
    with :ok <- ensure_release_ready(profile) do
      SddOrchestrator.HostedAccess.DeliveryConfiguration.ensure_production_ready(
        delivery_configuration
      )
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false

  defp invalid_backup_fields(configuration) when is_map(configuration) do
    evidence_errors =
      Enum.reject(@backup_evidence_fields, fn field ->
        configuration |> Map.get(field) |> evidence_present?()
      end)

    contract_errors =
      []
      |> invalid_unless(:encrypted, Map.get(configuration, :encrypted) == true)
      |> invalid_unless(
        :maximum_expiry_days,
        valid_backup_expiry?(Map.get(configuration, :maximum_expiry_days))
      )
      |> invalid_unless(
        :restore_scope,
        Map.get(configuration, :restore_scope) == :approved_recovery_only
      )
      |> invalid_unless(
        :deletion_propagation,
        Map.get(configuration, :deletion_propagation) == :required
      )

    Enum.uniq(evidence_errors ++ contract_errors)
  end

  defp invalid_backup_fields(_configuration), do: [:encrypted_backup_configuration]

  defp valid_backup_expiry?(days) do
    is_integer(days) and days > 0 and
      days <= @backup_lifecycle_contract.maximum_expiry_days
  end

  defp evidence_present?(value) when is_binary(value), do: String.trim(value) != ""

  defp evidence_present?(value) when is_list(value) do
    value != [] and Enum.all?(value, &evidence_present?/1)
  end

  defp evidence_present?(_value), do: false

  defp invalid_unless(errors, _field, true), do: errors
  defp invalid_unless(errors, field, false), do: errors ++ [field]
end
