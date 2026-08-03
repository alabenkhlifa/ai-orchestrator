defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessment do
  @moduledoc """
  The minimized authoritative binding for one repository assessment.

  A newly authorized assessment is persisted as `pending_scan`. Creating this
  value records the exact repository binding and confirmed processing-boundary
  digest, but does not enqueue or issue a worker command.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparation

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @state "pending_scan"

  @persisted_fields [
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
  ]

  @value_keys MapSet.new(Enum.map(@persisted_fields, &Atom.to_string/1))

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
      state: @state,
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
    if MapSet.new(Map.keys(value)) == @value_keys do
      value
      |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
      |> build()
    else
      {:error, :invalid_assessment}
    end
  rescue
    ArgumentError -> {:error, :invalid_assessment}
  end

  def from_value(_value), do: {:error, :invalid_assessment}

  @doc "Returns the single state Task 8 may create."
  @spec pending_state() :: String.t()
  def pending_state, do: @state

  defp build(attrs) do
    %__MODULE__{}
    |> cast(attrs, @persisted_fields)
    |> validate_required(@persisted_fields)
    |> validate_inclusion(:state, [@state])
    |> validate_length(:repository_provider, max: 255, count: :bytes)
    |> validate_length(:repository_id, max: 255, count: :bytes)
    |> validate_format(:commit, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> validate_format(:scanner_contract_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:disclosure_digest, ~r/\A[0-9a-f]{64}\z/)
    |> apply_action(:insert)
    |> case do
      {:ok, assessment} -> {:ok, assessment}
      {:error, _changeset} -> {:error, :invalid_assessment}
    end
  end
end
