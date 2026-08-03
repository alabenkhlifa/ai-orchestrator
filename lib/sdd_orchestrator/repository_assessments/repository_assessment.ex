defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessment do
  @moduledoc """
  The minimized authoritative state for one repository assessment.

  A newly authorized assessment is persisted as `pending_scan`. Creating this
  value records the exact repository binding and confirmed processing-boundary
  digest, but does not enqueue or issue a worker command. One exact command may
  later move it once to a minimized completed, canceled, or failed state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation
  }

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @pending_state "pending_scan"
  @terminal_states RepositoryAssessmentResult.statuses()

  @binding_fields [
    :id,
    :project_id,
    :repository_provider,
    :repository_id,
    :root,
    :commit,
    :scanner_contract_digest,
    :disclosure_digest,
    :worker_ref,
    :scan_protocol_version,
    :scan_limits,
    :boundary_confirmed_at,
    :inserted_at,
    :updated_at
  ]

  @result_fields [
    :findings,
    :structure,
    :stats,
    :failure_code,
    :terminal_at
  ]

  @persisted_fields [:state | @binding_fields ++ @result_fields]

  @value_keys MapSet.new(Enum.map(@persisted_fields, &Atom.to_string/1))

  @legacy_pending_value_keys MapSet.new(
                               Enum.map(
                                 [
                                   :id,
                                   :project_id,
                                   :repository_provider,
                                   :repository_id,
                                   :root,
                                   :commit,
                                   :scanner_contract_digest,
                                   :disclosure_digest,
                                   :worker_ref,
                                   :state,
                                   :boundary_confirmed_at,
                                   :inserted_at,
                                   :updated_at
                                 ],
                                 &Atom.to_string/1
                               )
                             )

  @type t :: %__MODULE__{}

  schema "repository_assessments" do
    field :repository_provider, :string
    field :repository_id, :string
    field :root, :string
    field :commit, :string
    field :scanner_contract_digest, :string
    field :disclosure_digest, :string
    field :worker_ref, :binary_id
    field :state, :string
    field :boundary_confirmed_at, :utc_datetime_usec
    field :scan_protocol_version, :integer
    field :scan_limits, :map
    field :findings, {:array, :map}
    field :structure, {:array, :map}
    field :stats, :map
    field :failure_code, :string
    field :terminal_at, :utc_datetime_usec

    belongs_to :project, SddOrchestrator.Projects.Project

    timestamps()
  end

  @doc "Builds the sole Task 8 state transition from a consumed trusted binding."
  @spec pending(RepositoryBindingPreparation.t(), DateTime.t()) ::
          {:ok, t()} | {:error, :invalid_assessment}
  def pending(%RepositoryBindingPreparation{} = preparation, %DateTime{} = now) do
    now = DateTime.truncate(now, :microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: preparation.project_id,
      repository_provider: preparation.repository_provider,
      repository_id: preparation.repository_id,
      root: preparation.root,
      commit: preparation.commit,
      scanner_contract_digest: preparation.scanner_contract_digest,
      disclosure_digest: preparation.disclosure_digest,
      worker_ref: preparation.worker_ref,
      scan_protocol_version: RepositoryAssessmentCommand.version(),
      scan_limits: stringify_limits(RepositoryAssessmentCommand.default_limits()),
      state: @pending_state,
      boundary_confirmed_at: preparation.issued_at,
      inserted_at: now,
      updated_at: now
    }

    if RepositoryBindingPreparation.valid?(preparation) do
      build(attrs)
    else
      {:error, :invalid_assessment}
    end
  end

  def pending(_preparation, _now), do: {:error, :invalid_assessment}

  @doc "Applies one exact command-bound pending-to-terminal transition in memory."
  @spec terminal(
          t(),
          RepositoryAssessmentCommand.t(),
          RepositoryAssessmentResult.t(),
          DateTime.t()
        ) ::
          {:ok, t()} | {:error, :already_terminal | :invalid_result | :stale}
  def terminal(
        %__MODULE__{state: @pending_state} = assessment,
        %RepositoryAssessmentCommand{} = command,
        %RepositoryAssessmentResult{} = result,
        %DateTime{} = now
      ) do
    cond do
      not RepositoryAssessmentResult.valid?(result) ->
        {:error, :invalid_result}

      not command_binding?(assessment, command) ->
        {:error, :stale}

      not RepositoryAssessmentResult.matches_command?(result, command) ->
        {:error, :stale}

      true ->
        now = DateTime.truncate(now, :microsecond)

        assessment
        |> Map.take(@persisted_fields)
        |> Map.merge(%{
          state: result.status,
          findings: result.findings,
          structure: result.structure,
          stats: result.stats,
          failure_code: result.failure_code,
          terminal_at: now,
          updated_at: now
        })
        |> build()
    end
  end

  def terminal(%__MODULE__{}, _command, _result, %DateTime{}),
    do: {:error, :already_terminal}

  def terminal(_assessment, _command, _result, _now), do: {:error, :invalid_result}

  @doc "Serializes the exact device-store value without Ecto metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = assessment) do
    assessment
    |> Map.take(@persisted_fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @doc "Restores only the allowlisted device-store value shape."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_assessment}
  def from_value(value) when is_map(value) do
    case MapSet.new(Map.keys(value)) do
      @value_keys ->
        build_from_value(value)

      @legacy_pending_value_keys ->
        value
        |> Map.merge(%{
          "scan_protocol_version" => RepositoryAssessmentCommand.version(),
          "scan_limits" => stringify_limits(RepositoryAssessmentCommand.default_limits()),
          "findings" => nil,
          "structure" => nil,
          "stats" => nil,
          "failure_code" => nil,
          "terminal_at" => nil
        })
        |> build_from_value()

      _unknown_shape ->
        {:error, :invalid_assessment}
    end
  rescue
    ArgumentError -> {:error, :invalid_assessment}
  end

  def from_value(_value), do: {:error, :invalid_assessment}

  @doc false
  @spec strict?(term()) :: boolean()
  def strict?(%__MODULE__{} = assessment) do
    value = to_value(assessment)

    case from_value(value) do
      {:ok, restored} -> to_value(restored) == value
      {:error, :invalid_assessment} -> false
    end
  rescue
    _error -> false
  end

  def strict?(_assessment), do: false

  @doc "Returns the single pending state Task 8 may create."
  @spec pending_state() :: String.t()
  def pending_state, do: @pending_state

  @spec terminal_state?(term()) :: boolean()
  def terminal_state?(state), do: state in @terminal_states

  @doc false
  @spec same_binding?(t(), t()) :: boolean()
  def same_binding?(%__MODULE__{} = left, %__MODULE__{} = right) do
    fields =
      @binding_fields -- [:updated_at]

    Map.take(left, fields) == Map.take(right, fields)
  end

  def same_binding?(_left, _right), do: false

  defp build(attrs) do
    %__MODULE__{}
    |> cast(attrs, @persisted_fields)
    |> validate_required([:state | @binding_fields])
    |> validate_inclusion(:state, [@pending_state | @terminal_states])
    |> validate_length(:repository_provider, max: 255, count: :bytes)
    |> validate_length(:repository_id, max: 255, count: :bytes)
    |> validate_format(:commit, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> validate_format(:scanner_contract_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:disclosure_digest, ~r/\A[0-9a-f]{64}\z/)
    |> apply_action(:insert)
    |> case do
      {:ok, assessment} -> validate_payload(assessment)
      {:error, _changeset} -> {:error, :invalid_assessment}
    end
  end

  defp build_from_value(value) do
    value
    |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
    |> build()
  end

  defp validate_payload(%__MODULE__{state: @pending_state} = assessment) do
    with true <- valid_scan_contract?(assessment),
         true <- Enum.all?(@result_fields, &is_nil(Map.get(assessment, &1))) do
      {:ok, assessment}
    else
      _invalid -> {:error, :invalid_assessment}
    end
  end

  defp validate_payload(%__MODULE__{} = assessment) do
    with true <- assessment.state in @terminal_states,
         true <- valid_scan_contract?(assessment),
         true <-
           Enum.all?(@result_fields -- [:failure_code], &(not is_nil(Map.get(assessment, &1)))),
         {:ok, result} <- RepositoryAssessmentResult.from_value(result_value(assessment)),
         true <- result.status == assessment.state do
      {:ok, assessment}
    else
      _invalid -> {:error, :invalid_assessment}
    end
  end

  defp result_value(assessment) do
    %{
      "version" => assessment.scan_protocol_version,
      "assessment_id" => assessment.id,
      "project_id" => assessment.project_id,
      "repository" => %{
        "provider" => assessment.repository_provider,
        "id" => assessment.repository_id
      },
      "root" => assessment.root,
      "commit" => assessment.commit,
      "scanner_contract_digest" => assessment.scanner_contract_digest,
      "disclosure_digest" => assessment.disclosure_digest,
      "worker_ref" => assessment.worker_ref,
      "limits" => assessment.scan_limits,
      "status" => assessment.state,
      "findings" => assessment.findings,
      "structure" => assessment.structure,
      "stats" => assessment.stats,
      "failure_code" => assessment.failure_code
    }
  end

  defp command_binding?(assessment, command) do
    RepositoryAssessmentCommand.valid?(command) and
      assessment.id == command.assessment_id and
      assessment.project_id == command.project_id and
      assessment.repository_provider == command.repository_provider and
      assessment.repository_id == command.repository_id and
      assessment.root == command.root and
      assessment.commit == command.commit and
      assessment.scanner_contract_digest == command.scanner_contract_digest and
      assessment.disclosure_digest == command.disclosure_digest and
      assessment.worker_ref == command.worker_ref and
      assessment.scan_protocol_version == command.version and
      assessment.scan_limits == stringify_limits(command.limits)
  end

  defp valid_scan_contract?(assessment) do
    with true <- assessment.scan_protocol_version == RepositoryAssessmentCommand.version(),
         limits when is_map(limits) <- atomize_limits(assessment.scan_limits),
         {:ok, command} <-
           RepositoryAssessmentCommand.new(%{assessment | state: @pending_state}, limits) do
      command.version == assessment.scan_protocol_version and
        stringify_limits(command.limits) == assessment.scan_limits
    else
      _invalid -> false
    end
  end

  defp atomize_limits(
         %{
           "max_paths" => max_paths,
           "max_files" => max_files,
           "max_total_bytes" => max_total_bytes,
           "max_file_bytes" => max_file_bytes,
           "timeout_ms" => timeout_ms
         } = limits
       )
       when map_size(limits) == 5 do
    %{
      max_paths: max_paths,
      max_files: max_files,
      max_total_bytes: max_total_bytes,
      max_file_bytes: max_file_bytes,
      timeout_ms: timeout_ms
    }
  end

  defp atomize_limits(_limits), do: :invalid

  defp stringify_limits(limits) do
    Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
