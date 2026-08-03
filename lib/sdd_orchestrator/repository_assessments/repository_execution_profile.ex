defmodule SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfile do
  @moduledoc """
  One immutable owner-approved repository execution profile version.

  Every field is copied from a strict proposal bound to one completed
  assessment. Versions are append-only; this schema intentionally exposes only
  a create changeset and stores no repository content, credentials, or worker
  diagnostics.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryBindingPreparation,
    RepositoryExecutionProfileProposal
  }

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @fields [
    :id,
    :project_id,
    :assessment_id,
    :version,
    :repository_provider,
    :repository_id,
    :root,
    :base_revision,
    :assessment_digest,
    :proposal_digest,
    :instruction_precedence,
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers,
    :approval_actor_ref,
    :approved_at,
    :inserted_at
  ]

  @value_keys MapSet.new(Enum.map(@fields, &Atom.to_string/1))

  @required_scalar_fields @fields --
                            [
                              :instruction_precedence,
                              :commands,
                              :required_checks,
                              :allowed_scope,
                              :gaps,
                              :conflicts,
                              :multi_root_blockers
                            ]

  @type t :: %__MODULE__{}

  schema "repository_execution_profiles" do
    field :version, :integer
    field :repository_provider, :string
    field :repository_id, :string
    field :root, :string
    field :base_revision, :string
    field :assessment_digest, :string
    field :proposal_digest, :string
    field :instruction_precedence, {:array, :map}
    field :commands, {:array, :string}
    field :required_checks, {:array, :string}
    field :allowed_scope, {:array, :string}
    field :gaps, {:array, :string}
    field :conflicts, {:array, :string}
    field :multi_root_blockers, {:array, :string}
    field :approval_actor_ref, :binary_id
    field :approved_at, :utc_datetime_usec

    belongs_to :project, SddOrchestrator.Projects.Project
    belongs_to :assessment, SddOrchestrator.RepositoryAssessments.RepositoryAssessment

    timestamps()
  end

  @doc "Creates one exact immutable version from a valid proposal."
  @spec approved(
          RepositoryExecutionProfileProposal.t(),
          Ecto.UUID.t(),
          pos_integer(),
          DateTime.t()
        ) ::
          {:ok, t()} | {:error, :invalid_profile}
  def approved(
        %RepositoryExecutionProfileProposal{} = proposal,
        actor_ref,
        version,
        %DateTime{} = approved_at
      ) do
    attrs =
      proposal
      |> Map.take([
        :project_id,
        :assessment_id,
        :repository_provider,
        :repository_id,
        :root,
        :assessment_digest,
        :proposal_digest,
        :instruction_precedence,
        :commands,
        :required_checks,
        :allowed_scope,
        :gaps,
        :conflicts,
        :multi_root_blockers
      ])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        version: version,
        base_revision: proposal.base_revision,
        approval_actor_ref: actor_ref,
        approved_at: DateTime.truncate(approved_at, :microsecond),
        inserted_at: DateTime.truncate(approved_at, :microsecond)
      })

    if RepositoryExecutionProfileProposal.valid?(proposal) do
      build(attrs)
    else
      {:error, :invalid_profile}
    end
  end

  def approved(_proposal, _actor_ref, _version, _approved_at), do: {:error, :invalid_profile}

  @doc "Create-only hosted changeset with immutable-version constraints."
  @spec create_changeset(t()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = profile) do
    %__MODULE__{}
    |> changeset(Map.take(profile, @fields))
    |> unique_constraint([:project_id, :version],
      name: :repository_execution_profiles_project_version_index
    )
    |> unique_constraint([:project_id, :assessment_id, :proposal_digest],
      name: :repository_execution_profiles_project_assessment_proposal_index
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:assessment_id)
    |> check_constraint(:version, name: :repository_execution_profiles_version_positive)
    |> check_constraint(:base_revision, name: :repository_execution_profiles_commit_shape)
    |> check_constraint(:assessment_digest, name: :repository_execution_profiles_digest_shape)
  end

  @doc "Serializes the exact device-authoritative value without Ecto metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = profile) do
    profile
    |> Map.take(@fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @doc "Restores only the exact immutable device value."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_profile}
  def from_value(value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @value_keys,
         {:ok, approved_at, 0} <- DateTime.from_iso8601(value["approved_at"]),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(value["inserted_at"]) do
      value
      |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
      |> Map.merge(%{approved_at: approved_at, inserted_at: inserted_at})
      |> build()
    else
      _invalid -> {:error, :invalid_profile}
    end
  rescue
    _error -> {:error, :invalid_profile}
  end

  def from_value(_value), do: {:error, :invalid_profile}

  @doc false
  @spec strict?(term()) :: boolean()
  def strict?(%__MODULE__{} = profile) do
    value = to_value(profile)

    case from_value(value) do
      {:ok, restored} -> to_value(restored) == value
      {:error, :invalid_profile} -> false
    end
  rescue
    _error -> false
  end

  def strict?(_profile), do: false

  @doc false
  @spec proposal_value(t()) :: map()
  def proposal_value(%__MODULE__{} = profile) do
    %{
      "assessment_id" => profile.assessment_id,
      "assessment_digest" => profile.assessment_digest,
      "project_id" => profile.project_id,
      "repository_provider" => profile.repository_provider,
      "repository_id" => profile.repository_id,
      "root" => profile.root,
      "base_revision" => profile.base_revision,
      "instruction_precedence" => profile.instruction_precedence,
      "commands" => profile.commands,
      "required_checks" => profile.required_checks,
      "allowed_scope" => profile.allowed_scope,
      "gaps" => profile.gaps,
      "conflicts" => profile.conflicts,
      "multi_root_blockers" => profile.multi_root_blockers,
      "proposal_digest" => profile.proposal_digest
    }
  end

  defp build(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
    |> case do
      {:ok, profile} -> validate_payload(profile)
      {:error, _changeset} -> {:error, :invalid_profile}
    end
  end

  defp changeset(profile, attrs) do
    profile
    |> cast(attrs, @fields)
    |> validate_required(@required_scalar_fields)
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:repository_provider, max: 255, count: :bytes)
    |> validate_length(:repository_id, max: 255, count: :bytes)
    |> validate_format(:base_revision, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> validate_format(:assessment_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:proposal_digest, ~r/\A[0-9a-f]{64}\z/)
  end

  defp validate_payload(profile) do
    with {:ok, proposal} <-
           RepositoryExecutionProfileProposal.from_value(proposal_value(profile)),
         true <- proposal.proposal_digest == profile.proposal_digest,
         {:ok, normalized_root} <- RepositoryBindingPreparation.normalize_root(profile.root),
         true <- normalized_root == profile.root,
         {:ok, _actor_ref} <- Ecto.UUID.cast(profile.approval_actor_ref),
         true <- DateTime.compare(profile.inserted_at, profile.approved_at) == :eq do
      {:ok, profile}
    else
      _invalid -> {:error, :invalid_profile}
    end
  end
end
