defmodule SddOrchestrator.Delivery.InitializationManifest do
  @moduledoc """
  One immutable, project-independent dispatch manifest and its stable digest.

  A manifest binds one pre-project `InitializationDispatch` to the confirmed
  device workspace, an explicit read-only or staging-write capability grant,
  the configured agent reference, and the opaque turn or build content the
  agent receives. It carries identities, an enum, and opaque configured
  content only — no project, feature, run, or filesystem identity, since none
  of those exist before this slice creates the first project.

  This type is deliberately independent of `SddOrchestrator.Delivery.ExecutionManifest`:
  that manifest's `project_id`/`feature_id`/specification-revision keys cannot
  exist pre-project, and this type must not import or depend on it.
  """

  alias SddOrchestrator.Delivery.{CanonicalJson, ProtocolLimits, SecretBoundary, WorkerProtocol}

  @manifest_version 1
  @capability_grants ~w(plan_discovery staging_write)

  @enforce_keys [
    :manifest_version,
    :device_workspace_id,
    :dispatch_id,
    :capability_grant,
    :agent_ref,
    :instructions
  ]

  defstruct @enforce_keys

  @type reference_map :: %{required(String.t()) => String.t()}

  @type t :: %__MODULE__{
          manifest_version: pos_integer(),
          device_workspace_id: String.t(),
          dispatch_id: String.t(),
          capability_grant: String.t(),
          agent_ref: reference_map(),
          instructions: map()
        }

  @spec manifest_version() :: pos_integer()
  def manifest_version, do: @manifest_version

  @spec capability_grants() :: [String.t()]
  def capability_grants, do: @capability_grants

  @doc """
  Builds one validated manifest from string-keyed attributes.
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with :ok <- SecretBoundary.validate(attrs),
         {:ok, fields} <- fetch_fields(attrs),
         :ok <- validate_fields(fields),
         manifest <- struct!(__MODULE__, fields),
         :ok <- validate_size(manifest) do
      {:ok, manifest}
    end
  end

  def new(_attrs), do: {:error, :invalid_manifest}

  @doc """
  Rebuilds one manifest from its decoded protocol representation.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, atom()}
  def from_map(%{"manifest_version" => @manifest_version} = value), do: new(value)
  def from_map(%{"manifest_version" => _other}), do: {:error, :unsupported_manifest_version}
  def from_map(_value), do: {:error, :invalid_manifest}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc """
  Returns the stable digest of one manifest.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = manifest) do
    {:ok, canonical} = CanonicalJson.encode(to_map(manifest))

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, atom()}
  def encode(%__MODULE__{} = manifest) do
    with {:ok, encoded} <- CanonicalJson.encode(to_map(manifest)),
         :ok <- validate_encoded_size(encoded) do
      {:ok, encoded}
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(encoded) when is_binary(encoded) do
    with :ok <- validate_encoded_size(encoded),
         {:ok, decoded} <- CanonicalJson.decode(encoded),
         true <- is_map(decoded) do
      from_map(decoded)
    else
      false -> {:error, :invalid_manifest}
      {:error, _reason} = error -> error
    end
  end

  def decode(_encoded), do: {:error, :invalid_manifest}

  defp fetch_fields(attrs) do
    Enum.reduce_while(@enforce_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(attrs, Atom.to_string(key)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, :missing_manifest_field}}
      end
    end)
    |> case do
      {:ok, fields} -> reject_unknown_fields(attrs, fields)
      {:error, _reason} = error -> error
    end
  end

  defp reject_unknown_fields(attrs, fields) do
    if map_size(attrs) == length(@enforce_keys) do
      {:ok, fields}
    else
      {:error, :unknown_manifest_field}
    end
  end

  defp validate_fields(fields) do
    with :ok <- validate_version(fields.manifest_version),
         :ok <- validate_device_workspace_id(fields.device_workspace_id),
         :ok <- validate_dispatch_id(fields.dispatch_id),
         :ok <- validate_capability_grant(fields.capability_grant),
         :ok <- validate_reference(fields.agent_ref, :invalid_agent_ref) do
      validate_instructions(fields.instructions)
    end
  end

  defp validate_version(@manifest_version), do: :ok
  defp validate_version(_version), do: {:error, :unsupported_manifest_version}

  defp validate_device_workspace_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_device_workspace_id}
    end
  end

  defp validate_device_workspace_id(_value), do: {:error, :invalid_device_workspace_id}

  defp validate_dispatch_id(value) do
    if WorkerProtocol.valid_id?(value), do: :ok, else: {:error, :invalid_dispatch_id}
  end

  defp validate_capability_grant(value) do
    if value in @capability_grants,
      do: :ok,
      else: {:error, :invalid_capability_grant}
  end

  defp validate_reference(reference, error) when is_map(reference) and not is_struct(reference) do
    max_bytes = ProtocolLimits.get(:max_reference_bytes)

    valid? =
      Enum.all?(reference, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          key != "" and byte_size(key) <= max_bytes and byte_size(value) <= max_bytes

        _other ->
          false
      end)

    if valid?, do: :ok, else: {:error, error}
  end

  defp validate_reference(_reference, error), do: {:error, error}

  defp validate_instructions(instructions)
       when is_map(instructions) and not is_struct(instructions),
       do: :ok

  defp validate_instructions(_instructions), do: {:error, :invalid_instructions}

  defp validate_size(manifest) do
    with {:ok, _encoded} <- encode(manifest), do: :ok
  end

  defp validate_encoded_size(encoded) do
    if byte_size(encoded) <= ProtocolLimits.get(:max_manifest_bytes),
      do: :ok,
      else: {:error, :manifest_too_large}
  end
end
