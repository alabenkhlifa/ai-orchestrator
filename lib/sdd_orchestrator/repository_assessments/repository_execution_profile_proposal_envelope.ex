defmodule SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfileProposalEnvelope do
  @moduledoc """
  The authoritative minimized proposal envelope of one completed assessment.

  The worker builds the transient delivery value while evidence is still local.
  Authoritative storage keeps only the six managed-runtime proposal fields and
  the digests that bind them to one exact completed assessment, because every
  command-owned field is already owned by that assessment. Validation rebuilds
  the worker envelope from the stored assessment, so a value bound to another
  assessment, another command, or replaced proposal fields can never be stored
  or read back.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @proposal_fields [
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers
  ]

  @digest_fields [
    :cache_key_sha256,
    :evidence_sha256,
    :result_sha256,
    :payload_digest,
    :envelope_digest
  ]

  @fields [:id, :project_id, :assessment_id, :version] ++
            @digest_fields ++ @proposal_fields ++ [:inserted_at]

  @required_scalar_fields @fields -- @proposal_fields

  @value_keys MapSet.new(Enum.map(@fields, &Atom.to_string/1))

  @type t :: %__MODULE__{}

  schema "repository_assessment_proposal_envelopes" do
    field :version, :integer
    field :cache_key_sha256, :string
    field :evidence_sha256, :string
    field :result_sha256, :string
    field :payload_digest, :string
    field :envelope_digest, :string
    field :commands, {:array, :string}
    field :required_checks, {:array, :string}
    field :allowed_scope, {:array, :string}
    field :gaps, {:array, :string}
    field :conflicts, {:array, :string}
    field :multi_root_blockers, {:array, :string}

    belongs_to :project, SddOrchestrator.Projects.Project
    belongs_to :assessment, SddOrchestrator.RepositoryAssessments.RepositoryAssessment

    timestamps()
  end

  @doc """
  Builds the authoritative value from one current worker delivery.

  The completed assessment supplies the command, terminal result, and Task 13
  cache provenance the envelope must already be bound to.
  """
  @spec new(term(), term(), DateTime.t()) :: {:ok, t()} | {:error, :invalid_proposal_envelope}
  def new(
        %WorkerRepositoryExecutionProfileProposalEnvelope{} = delivered,
        %RepositoryAssessment{state: "completed"} = assessment,
        %DateTime{} = now
      ) do
    with {:ok, rebuilt} <- rebuild(Map.take(delivered, @proposal_fields), assessment),
         true <- rebuilt == delivered do
      build(%{
        id: Ecto.UUID.generate(),
        project_id: assessment.project_id,
        assessment_id: assessment.id,
        version: rebuilt.version,
        cache_key_sha256: rebuilt.cache_key_sha256,
        evidence_sha256: rebuilt.evidence_sha256,
        result_sha256: rebuilt.result_sha256,
        payload_digest: rebuilt.payload_digest,
        envelope_digest: rebuilt.envelope_digest,
        commands: rebuilt.commands,
        required_checks: rebuilt.required_checks,
        allowed_scope: rebuilt.allowed_scope,
        gaps: rebuilt.gaps,
        conflicts: rebuilt.conflicts,
        multi_root_blockers: rebuilt.multi_root_blockers,
        inserted_at: DateTime.truncate(now, :microsecond)
      })
    else
      _invalid -> {:error, :invalid_proposal_envelope}
    end
  rescue
    _error -> {:error, :invalid_proposal_envelope}
  end

  def new(_delivered, _assessment, _now), do: {:error, :invalid_proposal_envelope}

  @doc "Confirms one stored envelope is still the exact delivery of its assessment."
  @spec verify(term(), term()) :: {:ok, t()} | {:error, :invalid_proposal_envelope}
  def verify(%__MODULE__{} = envelope, %RepositoryAssessment{state: "completed"} = assessment) do
    with true <- strict?(envelope),
         true <- envelope.project_id == assessment.project_id,
         true <- envelope.assessment_id == assessment.id,
         true <- envelope.cache_key_sha256 == assessment.cache_key_sha256,
         true <- envelope.evidence_sha256 == assessment.evidence_sha256,
         {:ok, rebuilt} <- rebuild(proposal_fields(envelope), assessment),
         true <- rebuilt.version == envelope.version,
         true <- rebuilt.cache_key_sha256 == envelope.cache_key_sha256,
         true <- rebuilt.evidence_sha256 == envelope.evidence_sha256,
         true <- rebuilt.result_sha256 == envelope.result_sha256,
         true <- rebuilt.payload_digest == envelope.payload_digest,
         true <- rebuilt.envelope_digest == envelope.envelope_digest do
      {:ok, envelope}
    else
      _invalid -> {:error, :invalid_proposal_envelope}
    end
  rescue
    _error -> {:error, :invalid_proposal_envelope}
  end

  def verify(_envelope, _assessment), do: {:error, :invalid_proposal_envelope}

  @doc "Returns only the six managed-runtime proposal fields Task 11 reconstructs."
  @spec proposal_fields(t()) :: map()
  def proposal_fields(%__MODULE__{} = envelope), do: Map.take(envelope, @proposal_fields)

  @doc "Create-only hosted changeset with its exact-assessment constraints."
  @spec create_changeset(t()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = envelope) do
    %__MODULE__{}
    |> changeset(Map.take(envelope, @fields))
    |> unique_constraint(:assessment_id,
      name: :repository_assessment_proposal_envelopes_assessment_index
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:assessment_id)
    |> check_constraint(:version,
      name: :repository_assessment_proposal_envelopes_version_positive
    )
    |> check_constraint(:envelope_digest,
      name: :repository_assessment_proposal_envelopes_digest_shape
    )
  end

  @doc "Serializes the exact device-authoritative value without Ecto metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = envelope) do
    envelope
    |> Map.take(@fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @doc "Restores only the exact minimized device value."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_proposal_envelope}
  def from_value(value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @value_keys,
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(value["inserted_at"]) do
      value
      |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
      |> Map.put(:inserted_at, inserted_at)
      |> build()
    else
      _invalid -> {:error, :invalid_proposal_envelope}
    end
  rescue
    _error -> {:error, :invalid_proposal_envelope}
  end

  def from_value(_value), do: {:error, :invalid_proposal_envelope}

  @doc false
  @spec strict?(term()) :: boolean()
  def strict?(%__MODULE__{} = envelope) do
    value = to_value(envelope)

    case from_value(value) do
      {:ok, restored} -> to_value(restored) == value
      {:error, :invalid_proposal_envelope} -> false
    end
  rescue
    _error -> false
  end

  def strict?(_envelope), do: false

  defp rebuild(fields, assessment) do
    with true <- RepositoryAssessment.strict?(assessment),
         true <- RepositoryAssessment.cache_provenance_complete?(assessment),
         {:ok, command} <- RepositoryAssessment.command(assessment),
         {:ok, result} <- RepositoryAssessment.result(assessment),
         {:ok, payload} <- RepositoryExecutionProfileProposalPayload.new(result, fields),
         {:ok, rebuilt} <-
           WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result) do
      {:ok, rebuilt}
    else
      _invalid -> {:error, :invalid_proposal_envelope}
    end
  end

  defp build(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
    |> case do
      {:ok, envelope} -> validate_proposal_lists(envelope)
      {:error, _changeset} -> {:error, :invalid_proposal_envelope}
    end
  end

  defp validate_proposal_lists(envelope) do
    if Enum.all?(@proposal_fields, &binary_list?(Map.get(envelope, &1))) do
      {:ok, envelope}
    else
      {:error, :invalid_proposal_envelope}
    end
  end

  defp binary_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)

  defp changeset(envelope, attrs) do
    envelope
    |> cast(attrs, @fields)
    |> validate_required(@required_scalar_fields)
    |> validate_number(:version, greater_than: 0)
    |> validate_digests()
  end

  defp validate_digests(changeset) do
    Enum.reduce(@digest_fields, changeset, fn field, acc ->
      validate_format(acc, field, ~r/\A[0-9a-f]{64}\z/)
    end)
  end
end
