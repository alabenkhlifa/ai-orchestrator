defmodule SddOrchestrator.Privacy.DeploymentPrivacyProfile do
  @moduledoc """
  Deployment-specific privacy release evidence and its release gate.

  The stable implementation contract is approved (see `ProcessingInventory`), but a
  public hosted deployment must additionally record the controller identity and
  contact, processor list, hosting and backup regions, cross-border transfer
  safeguards, privacy notice, incident path, retention enforcement, and completed
  reviews. A profile missing any of these blocks release — and only release: it does
  not block implementation or local verification, so this gate is a separate,
  explicit readiness check rather than part of `mix release`.
  """
  @required [
    :controller_contact,
    :processors,
    :hosting_regions,
    :transfer_safeguards,
    :privacy_notice,
    :incident_path,
    :retention_enforcement,
    :reviews
  ]

  defstruct Enum.map(@required, &{&1, nil})

  @type t :: %__MODULE__{}

  @doc "The deployment evidence fields required before a public hosted release."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required

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

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false
end
