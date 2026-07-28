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

  @doc "The deployment evidence fields required before a public hosted release."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required

  @doc "Infrastructure-enforced expiry ceilings required by the privacy release gate."
  @spec retention_requirements() :: %{
          operational_security_logs_days: pos_integer(),
          encrypted_rolling_backups_days: pos_integer()
        }
  def retention_requirements, do: @retention_requirements

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
end
