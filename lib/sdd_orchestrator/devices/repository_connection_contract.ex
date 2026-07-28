defmodule SddOrchestrator.Devices.RepositoryConnectionContract do
  @moduledoc """
  The exhaustive set of metadata permitted to leave the device during local
  onboarding.

  Only an opaque connection id, the owning workspace and worker ids, the
  non-reversible repository fingerprint, coarse compatibility descriptors, and a
  connection status may cross the boundary. Local paths, remote URLs, filenames,
  Git history, and source content must never appear. `build/1` fails closed: it
  rejects any prohibited or unexpected field rather than silently dropping it, so
  a worker that tries to send more than the contract cannot.

  The user-chosen project name travels through project registration, not this
  contract.
  """

  alias SddOrchestrator.Devices.PortableRepositoryIdentity

  @enforce_keys [:workspace_id, :worker_id, :repository_fingerprint, :status]
  defstruct [
    :connection_id,
    :workspace_id,
    :worker_id,
    :repository_fingerprint,
    :status,
    compatibility: %{}
  ]

  @type t :: %__MODULE__{}

  @allowed_fields ~w(connection_id workspace_id worker_id repository_fingerprint status compatibility)a
  @allowed_compatibility ~w(app_version protocol_version os_family os_major)a
  @statuses ~w(connected unavailable authorization_required invalid)

  # A representative denylist of data that must stay on the device. Enforcement is
  # allowlist-first (only_allowed/1); this list makes prohibited intent explicit
  # and gives privacy tests concrete cases.
  @prohibited_fields ~w(
    path full_path absolute_path remote_url url html_url clone_url
    filename filenames file_list git_history history commits log
    source source_code content blob diff owner organization
  )a

  @doc "The only fields permitted in an outbound contract."
  def allowed_fields, do: @allowed_fields

  @doc "The only compatibility descriptors permitted."
  def allowed_compatibility_fields, do: @allowed_compatibility

  @doc "Representative fields that must never leave the device."
  def prohibited_fields, do: @prohibited_fields

  @doc "The permitted connection statuses."
  def statuses, do: @statuses

  @doc """
  Builds a validated outbound contract from worker-supplied attributes, rejecting
  any prohibited, unexpected, or missing field and any invalid status.
  """
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_map(attrs) do
    attrs = atomize(attrs)

    with :ok <- reject_prohibited(attrs, @prohibited_fields),
         :ok <- only_allowed(attrs, @allowed_fields, :unexpected_field),
         {:ok, compatibility} <- build_compatibility(Map.get(attrs, :compatibility, %{})),
         :ok <- require_fields(attrs, @enforce_keys),
         :ok <- validate_repository_fingerprint(Map.get(attrs, :repository_fingerprint)),
         :ok <- validate_status(Map.get(attrs, :status)) do
      {:ok,
       %__MODULE__{
         connection_id: Map.get(attrs, :connection_id),
         workspace_id: Map.fetch!(attrs, :workspace_id),
         worker_id: Map.fetch!(attrs, :worker_id),
         repository_fingerprint: Map.fetch!(attrs, :repository_fingerprint),
         status: Map.fetch!(attrs, :status),
         compatibility: compatibility
       }}
    end
  end

  defp build_compatibility(compatibility) when is_map(compatibility) do
    compatibility = atomize(compatibility)

    with :ok <- reject_prohibited(compatibility, @prohibited_fields),
         :ok <-
           only_allowed(compatibility, @allowed_compatibility, :unexpected_compatibility_field) do
      {:ok, compatibility}
    end
  end

  defp build_compatibility(_), do: {:error, :invalid_compatibility}

  defp reject_prohibited(attrs, prohibited) do
    case Enum.find(Map.keys(attrs), &(&1 in prohibited)) do
      nil -> :ok
      field -> {:error, {:prohibited_field, field}}
    end
  end

  defp only_allowed(attrs, allowed, error) do
    case Enum.find(Map.keys(attrs), &(&1 not in allowed)) do
      nil -> :ok
      field -> {:error, {error, field}}
    end
  end

  defp require_fields(attrs, required) do
    case Enum.find(required, &(is_nil(Map.get(attrs, &1)) or Map.get(attrs, &1) == "")) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  defp validate_status(status) when status in @statuses, do: :ok
  defp validate_status(status), do: {:error, {:invalid_status, status}}

  defp validate_repository_fingerprint(fingerprint) do
    case PortableRepositoryIdentity.parse(fingerprint) do
      {:ok, _portable} -> :ok
      {:error, _reason} -> {:error, :invalid_repository_fingerprint}
    end
  end

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_atom(k), v}
    end)
  end

  # Unknown string keys become a sentinel so they fail allowlist checks instead of
  # creating new atoms from untrusted worker input.
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end
end
