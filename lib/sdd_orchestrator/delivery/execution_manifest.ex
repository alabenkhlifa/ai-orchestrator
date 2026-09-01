defmodule SddOrchestrator.Delivery.ExecutionManifest do
  @moduledoc """
  One immutable execution manifest and its stable digest.

  A manifest binds one attempt to the exact starting and effective
  specification revisions, the approved slice, the repository base revision,
  the isolated target branch, the snapshotted required-check contract, the
  approved repository root, commands, and allowed scope, the configured agent
  and worker references, and the continuation reason.

  It carries identities, digests, and opaque configured references only.
  Specification documents, repository content, and credentials stay outside
  the manifest so the same value can travel over the worker channel and be
  digested for replay comparison. The repository root is the one path-like
  value, and it is the root the repository's owner approved.

  `repository_root`, `commands`, and `allowed_scope` are their own typed
  fields rather than entries in `agent_ref` or `worker_ref`, because those two
  references are flat maps capped at `ProtocolLimits.max_reference_bytes` per
  value while an approved profile holds far larger lists. They default to
  empty so a manifest built by a path that has not yet moved onto the approved
  profile is still a valid manifest.

  Those three fields arrived with `manifest_version` 2. The version was raised
  because a manifest carries no unknown field: a worker that only knows
  version 1 would otherwise refuse the new one as malformed. It refuses on the
  version instead, which is the answer that tells the reader what is wrong.
  """

  alias SddOrchestrator.Delivery.{
    CanonicalJson,
    ProtocolLimits,
    SecretBoundary,
    WorkerProtocol
  }

  @manifest_version 2
  @continuation_reasons ~w(automatic_retry blocking_answer initial manual_retry review_feedback)
  @branch_pattern ~r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @revision_pattern ~r/\A[0-9a-f]{7,64}\z/

  # The approved profile's own limits, mirrored here so a legitimate profile
  # can never produce a manifest this module refuses.
  @max_profile_entries 64
  @max_profile_entry_bytes 1_024

  @required_keys [
    :manifest_version,
    :project_id,
    :feature_id,
    :run_id,
    :attempt_number,
    :approved_slice,
    :starting_revision_id,
    :starting_revision_digest,
    :effective_revision_id,
    :effective_revision_digest,
    :repository_base_revision,
    :target_branch,
    :required_checks,
    :agent_ref,
    :worker_ref,
    :continuation
  ]

  @optional_defaults [repository_root: "", commands: [], allowed_scope: []]

  @field_names Enum.map(
                 @required_keys ++ Keyword.keys(@optional_defaults),
                 &Atom.to_string/1
               )

  @enforce_keys @required_keys

  defstruct @required_keys ++ @optional_defaults

  @type required_check :: %{required(String.t()) => String.t()}
  @type reference_map :: %{required(String.t()) => String.t()}

  @type t :: %__MODULE__{
          manifest_version: pos_integer(),
          project_id: String.t(),
          feature_id: String.t(),
          run_id: String.t(),
          attempt_number: pos_integer(),
          approved_slice: String.t(),
          starting_revision_id: String.t(),
          starting_revision_digest: String.t(),
          effective_revision_id: String.t(),
          effective_revision_digest: String.t(),
          repository_base_revision: String.t(),
          target_branch: String.t(),
          required_checks: [required_check()],
          repository_root: String.t(),
          commands: [String.t()],
          allowed_scope: [String.t()],
          agent_ref: reference_map(),
          worker_ref: reference_map(),
          continuation: map()
        }

  @spec manifest_version() :: pos_integer()
  def manifest_version, do: @manifest_version

  @spec continuation_reasons() :: [String.t()]
  def continuation_reasons, do: @continuation_reasons

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

  The digest covers the canonical encoding of every manifest field, so two
  peers that hold the same manifest always compute the same value regardless
  of map ordering, and any field change produces a different digest.
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
    with :ok <- reject_unknown_fields(attrs),
         {:ok, required} <- fetch_required_fields(attrs) do
      {:ok, put_optional_fields(attrs, required)}
    end
  end

  defp reject_unknown_fields(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @field_names)) do
      :ok
    else
      {:error, :unknown_manifest_field}
    end
  end

  defp fetch_required_fields(attrs) do
    Enum.reduce_while(@required_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(attrs, Atom.to_string(key)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, :missing_manifest_field}}
      end
    end)
  end

  # A manifest written before these fields existed still decodes: an absent
  # field takes its empty default rather than failing the whole manifest.
  defp put_optional_fields(attrs, fields) do
    Enum.reduce(@optional_defaults, fields, fn {key, default}, acc ->
      Map.put(acc, key, Map.get(attrs, Atom.to_string(key), default))
    end)
  end

  defp validate_fields(fields) do
    with :ok <- validate_version(fields.manifest_version),
         :ok <- validate_ids(fields),
         :ok <- validate_attempt_number(fields.attempt_number),
         :ok <- validate_text(fields.approved_slice, :invalid_approved_slice),
         :ok <- validate_revisions(fields),
         :ok <- validate_branch(fields.target_branch),
         :ok <- validate_required_checks(fields.required_checks),
         :ok <- validate_repository_root(fields.repository_root),
         :ok <- validate_profile_list(fields.commands, :invalid_commands),
         :ok <- validate_profile_list(fields.allowed_scope, :invalid_allowed_scope),
         :ok <- validate_reference(fields.agent_ref, :invalid_agent_ref),
         :ok <- validate_reference(fields.worker_ref, :invalid_worker_ref) do
      validate_continuation(fields.continuation, fields.attempt_number)
    end
  end

  defp validate_version(@manifest_version), do: :ok
  defp validate_version(_version), do: {:error, :unsupported_manifest_version}

  defp validate_ids(fields) do
    [fields.project_id, fields.feature_id, fields.run_id]
    |> Enum.all?(&WorkerProtocol.valid_id?/1)
    |> case do
      true -> :ok
      false -> {:error, :invalid_manifest_identity}
    end
  end

  defp validate_attempt_number(number) when is_integer(number) and number > 0, do: :ok
  defp validate_attempt_number(_number), do: {:error, :invalid_attempt_number}

  defp validate_text(value, error) do
    if is_binary(value) and value != "" and
         byte_size(value) <= ProtocolLimits.get(:max_text_bytes),
       do: :ok,
       else: {:error, error}
  end

  defp validate_revisions(fields) do
    with :ok <- validate_revision_id(fields.starting_revision_id),
         :ok <- validate_revision_id(fields.effective_revision_id),
         :ok <- validate_digest(fields.starting_revision_digest),
         :ok <- validate_digest(fields.effective_revision_digest) do
      validate_base_revision(fields.repository_base_revision)
    end
  end

  defp validate_revision_id(value) do
    if WorkerProtocol.valid_id?(value), do: :ok, else: {:error, :invalid_revision_id}
  end

  defp validate_digest(value) do
    if is_binary(value) and Regex.match?(@digest_pattern, value),
      do: :ok,
      else: {:error, :invalid_revision_digest}
  end

  defp validate_base_revision(value) do
    if is_binary(value) and Regex.match?(@revision_pattern, value),
      do: :ok,
      else: {:error, :invalid_base_revision}
  end

  defp validate_branch(value) do
    if is_binary(value) and byte_size(value) <= 255 and Regex.match?(@branch_pattern, value) and
         not String.contains?(value, "..") and not String.ends_with?(value, "/") do
      :ok
    else
      {:error, :invalid_target_branch}
    end
  end

  defp validate_required_checks(checks) when is_list(checks) do
    with :ok <- validate_check_count(checks),
         :ok <- validate_check_shapes(checks) do
      validate_unique_check_names(checks)
    end
  end

  defp validate_required_checks(_checks), do: {:error, :invalid_required_checks}

  defp validate_check_count(checks) do
    if length(checks) <= ProtocolLimits.get(:max_required_checks),
      do: :ok,
      else: {:error, :too_many_required_checks}
  end

  defp validate_check_shapes(checks) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case validate_check(check) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_check(%{"name" => name, "command" => command} = check)
       when map_size(check) == 2 do
    with :ok <- validate_text(name, :invalid_required_check) do
      validate_text(command, :invalid_required_check)
    end
  end

  defp validate_check(_check), do: {:error, :invalid_required_check}

  defp validate_unique_check_names(checks) do
    names = Enum.map(checks, &Map.fetch!(&1, "name"))

    if length(names) == length(Enum.uniq(names)),
      do: :ok,
      else: {:error, :duplicate_required_check}
  end

  # The root is allowed to be empty, unlike every other text field, because
  # empty means the builder carried no approved profile rather than an owner
  # approving a blank root.
  defp validate_repository_root(value) do
    if is_binary(value) and byte_size(value) <= @max_profile_entry_bytes,
      do: :ok,
      else: {:error, :invalid_repository_root}
  end

  defp validate_profile_list(values, error) when is_list(values) do
    if length(values) <= @max_profile_entries and Enum.all?(values, &profile_entry?/1),
      do: :ok,
      else: {:error, error}
  end

  defp validate_profile_list(_values, error), do: {:error, error}

  defp profile_entry?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= @max_profile_entry_bytes

  defp validate_reference(reference, error) when is_map(reference) do
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

  defp validate_continuation(
         %{"reason" => reason, "prior_attempt_number" => prior} = continuation,
         attempt_number
       )
       when map_size(continuation) == 2 do
    cond do
      reason not in @continuation_reasons -> {:error, :invalid_continuation_reason}
      reason == "initial" -> validate_initial_continuation(prior, attempt_number)
      true -> validate_prior_attempt_number(prior, attempt_number)
    end
  end

  defp validate_continuation(_continuation, _attempt_number), do: {:error, :invalid_continuation}

  defp validate_initial_continuation(nil, 1), do: :ok
  defp validate_initial_continuation(_prior, _attempt_number), do: {:error, :invalid_continuation}

  defp validate_prior_attempt_number(prior, attempt_number)
       when is_integer(prior) and prior > 0 and prior < attempt_number,
       do: :ok

  defp validate_prior_attempt_number(_prior, _attempt_number), do: {:error, :invalid_continuation}

  defp validate_size(manifest) do
    with {:ok, _encoded} <- encode(manifest), do: :ok
  end

  defp validate_encoded_size(encoded) do
    if byte_size(encoded) <= ProtocolLimits.get(:max_manifest_bytes),
      do: :ok,
      else: {:error, :manifest_too_large}
  end
end
