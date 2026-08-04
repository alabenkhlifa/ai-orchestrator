defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand do
  @moduledoc """
  Minimized command sent to a worker for one repository assessment.

  The command binds a pending assessment to its canonical repository, selected
  root, exact commit, scanner contract, confirmed disclosure, worker, and hard
  scan limits. It deliberately contains no filesystem path, credential, source
  content, or transport detail.
  """

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryBindingPreparation
  }

  @version 1

  @limit_keys [
    :max_paths,
    :max_files,
    :max_total_bytes,
    :max_file_bytes,
    :timeout_ms
  ]

  @default_limits %{
    max_paths: 2_000,
    max_files: 64,
    max_total_bytes: 512 * 1_024,
    max_file_bytes: 64 * 1_024,
    timeout_ms: 10_000
  }

  @maximum_limits %{
    max_paths: 10_000,
    max_files: 256,
    max_total_bytes: 2 * 1_024 * 1_024,
    max_file_bytes: 256 * 1_024,
    timeout_ms: 30_000
  }

  @fields [
    :version,
    :assessment_id,
    :project_id,
    :repository_provider,
    :repository_id,
    :root,
    :commit,
    :scanner_contract_digest,
    :disclosure_digest,
    :worker_ref,
    :limits
  ]

  @enforce_keys @fields
  defstruct @fields

  @type limits :: %{
          required(:max_paths) => pos_integer(),
          required(:max_files) => pos_integer(),
          required(:max_total_bytes) => pos_integer(),
          required(:max_file_bytes) => pos_integer(),
          required(:timeout_ms) => pos_integer()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          assessment_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          root: String.t(),
          commit: String.t(),
          scanner_contract_digest: String.t(),
          disclosure_digest: String.t(),
          worker_ref: Ecto.UUID.t(),
          limits: limits()
        }

  @spec version() :: pos_integer()
  def version, do: @version

  @spec default_limits() :: limits()
  def default_limits, do: @default_limits

  @doc "Builds a strict worker command from one pending authoritative assessment."
  @spec new(RepositoryAssessment.t(), map()) :: {:ok, t()} | {:error, :invalid_command}
  def new(assessment, limits \\ @default_limits)

  def new(%RepositoryAssessment{} = assessment, limits) do
    build(%{
      version: @version,
      assessment_id: assessment.id,
      project_id: assessment.project_id,
      repository_provider: assessment.repository_provider,
      repository_id: assessment.repository_id,
      root: assessment.root,
      commit: assessment.commit,
      scanner_contract_digest: assessment.scanner_contract_digest,
      disclosure_digest: assessment.disclosure_digest,
      worker_ref: assessment.worker_ref,
      limits: limits,
      state: assessment.state
    })
  end

  def new(_assessment, _limits), do: {:error, :invalid_command}

  @doc "Restores only the exact serialized command shape accepted by the worker."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_command}
  def from_value(value) when is_map(value) do
    with true <-
           MapSet.new(Map.keys(value)) ==
             MapSet.new(
               ~w(version assessment_id project_id repository root commit scanner_contract_digest disclosure_digest worker_ref limits)
             ),
         %{"provider" => provider, "id" => repository_id} = repository <-
           Map.fetch!(value, "repository"),
         true <- MapSet.new(Map.keys(repository)) == MapSet.new(~w(provider id)),
         {:ok, limits} <- limits_from_value(Map.fetch!(value, "limits")) do
      build(%{
        version: Map.fetch!(value, "version"),
        assessment_id: Map.fetch!(value, "assessment_id"),
        project_id: Map.fetch!(value, "project_id"),
        repository_provider: provider,
        repository_id: repository_id,
        root: Map.fetch!(value, "root"),
        commit: Map.fetch!(value, "commit"),
        scanner_contract_digest: Map.fetch!(value, "scanner_contract_digest"),
        disclosure_digest: Map.fetch!(value, "disclosure_digest"),
        worker_ref: Map.fetch!(value, "worker_ref"),
        limits: limits,
        state: RepositoryAssessment.pending_state()
      })
    else
      _invalid -> {:error, :invalid_command}
    end
  rescue
    _error -> {:error, :invalid_command}
  end

  def from_value(_value), do: {:error, :invalid_command}

  @doc "Serializes the allowlisted command value without worker-local paths."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = command) do
    %{
      "version" => command.version,
      "assessment_id" => command.assessment_id,
      "project_id" => command.project_id,
      "repository" => %{
        "provider" => command.repository_provider,
        "id" => command.repository_id
      },
      "root" => command.root,
      "commit" => command.commit,
      "scanner_contract_digest" => command.scanner_contract_digest,
      "disclosure_digest" => command.disclosure_digest,
      "worker_ref" => command.worker_ref,
      "limits" =>
        Map.new(@limit_keys, fn key -> {Atom.to_string(key), Map.fetch!(command.limits, key)} end)
    }
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = command) do
    case command |> to_value() |> from_value() do
      {:ok, ^command} -> true
      _invalid -> false
    end
  rescue
    _error -> false
  end

  def valid?(_command), do: false

  defp build(attrs) do
    with true <- attrs.version == @version,
         true <- attrs.state == RepositoryAssessment.pending_state(),
         {:ok, assessment_id} <- uuid(attrs.assessment_id),
         {:ok, project_id} <- uuid(attrs.project_id),
         {:ok, provider} <- identifier(attrs.repository_provider),
         {:ok, repository_id} <- identifier(attrs.repository_id),
         {:ok, root} <- RepositoryBindingPreparation.normalize_root(attrs.root),
         true <- root == attrs.root,
         {:ok, commit} <- RepositoryBindingPreparation.full_commit(attrs.commit),
         {:ok, scanner_digest} <-
           RepositoryBindingPreparation.digest(attrs.scanner_contract_digest),
         {:ok, disclosure_digest} <- RepositoryBindingPreparation.digest(attrs.disclosure_digest),
         {:ok, worker_ref} <- uuid(attrs.worker_ref),
         {:ok, limits} <- validate_limits(attrs.limits) do
      {:ok,
       %__MODULE__{
         version: @version,
         assessment_id: assessment_id,
         project_id: project_id,
         repository_provider: provider,
         repository_id: repository_id,
         root: root,
         commit: commit,
         scanner_contract_digest: scanner_digest,
         disclosure_digest: disclosure_digest,
         worker_ref: worker_ref,
         limits: limits
       }}
    else
      _invalid -> {:error, :invalid_command}
    end
  end

  defp validate_limits(limits) when is_map(limits) do
    with true <- MapSet.new(Map.keys(limits)) == MapSet.new(@limit_keys),
         true <-
           Enum.all?(@limit_keys, fn key ->
             value = Map.fetch!(limits, key)
             is_integer(value) and value > 0 and value <= Map.fetch!(@maximum_limits, key)
           end),
         true <- limits.max_file_bytes <= limits.max_total_bytes do
      {:ok, Map.take(limits, @limit_keys)}
    else
      _invalid -> {:error, :invalid_limits}
    end
  end

  defp validate_limits(_limits), do: {:error, :invalid_limits}

  defp limits_from_value(value) when is_map(value) do
    expected_keys = MapSet.new(Enum.map(@limit_keys, &Atom.to_string/1))

    if MapSet.new(Map.keys(value)) == expected_keys do
      limits = Map.new(@limit_keys, fn key -> {key, Map.fetch!(value, Atom.to_string(key))} end)
      validate_limits(limits)
    else
      {:error, :invalid_limits}
    end
  end

  defp limits_from_value(_value), do: {:error, :invalid_limits}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp uuid(_value), do: :error

  defp identifier(value) when is_binary(value) do
    normalized = String.trim(value)

    if normalized == value and byte_size(normalized) <= 255 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, normalized),
       do: {:ok, normalized},
       else: :error
  end

  defp identifier(_value), do: :error
end
