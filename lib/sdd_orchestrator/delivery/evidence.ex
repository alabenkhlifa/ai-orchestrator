defmodule SddOrchestrator.Delivery.Evidence do
  @moduledoc """
  One typed, immutable proof that something a run claims actually happened.

  An item of evidence is a command result, not a report about one. It carries
  the exact command, the exit code, the duration, the branch, and the commit it
  ran against, because a reader who was not there has to be able to check the
  outcome instead of trusting it. `agent` is not an allowed source at all: an
  agent's account of its own work is narrative, and narrative never satisfies a
  required check.

  Nothing recorded here is ever rewritten. A rerun, a correction, or a later
  disagreement records a new row and links the old one to it through
  `supersede_changeset/3`, which is the only changeset an existing row accepts.
  A database trigger enforces that rather than trusting callers, so a superseded
  or wrong result stays visible as part of the history it belongs to.

  Bytes live in the private artifact store. This row holds a content digest and,
  when there is one, an opaque artifact reference — never a public URL, never an
  embedded credential, and never the captured content itself.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.{AgentRun, Feature, RunAttempt}
  alias SddOrchestrator.Projects.Project

  @kinds ~w(required_check screenshot preview)
  @outcomes ~w(passed failed missing unsupported)

  # The worker's command runner and the check itself. The protocol also defines
  # `agent`, which is deliberately not accepted here.
  @sources ~w(check worker)

  @max_name_bytes 200
  @max_command_bytes 2_000
  @max_branch_bytes 200
  @max_commit_bytes 64
  @max_artifact_ref_bytes 512

  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "evidence" do
    field :command_id, :string
    field :kind, :string
    field :name, :string
    field :outcome, :string
    field :command, :string
    field :exit_code, :integer
    field :duration_ms, :integer
    field :branch, :string
    field :commit_sha, :string
    field :source, :string
    field :recorded_at, :utc_datetime_usec
    field :digest, :string
    field :redacted, :boolean, default: false
    field :artifact_ref, :string
    field :state_version, :integer, default: 1

    belongs_to :project, Project
    belongs_to :feature, Feature
    belongs_to :run, AgentRun
    belongs_to :attempt, RunAttempt
    belongs_to :superseded_by, __MODULE__

    timestamps()
  end

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec max_name_bytes() :: pos_integer()
  def max_name_bytes, do: @max_name_bytes

  @spec max_command_bytes() :: pos_integer()
  def max_command_bytes, do: @max_command_bytes

  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{superseded_by_id: superseded_by_id}), do: is_nil(superseded_by_id)

  @doc """
  Records one item of proof. There is deliberately no update changeset.

  The branch is supplied by the run rather than by the worker, so evidence can
  never claim work happened somewhere the run does not own.
  """
  def record_changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :command_id,
      :kind,
      :name,
      :outcome,
      :command,
      :exit_code,
      :duration_ms,
      :branch,
      :commit_sha,
      :source,
      :recorded_at,
      :digest,
      :redacted,
      :artifact_ref
    ])
    |> put_default_recorded_at()
    |> put_default_redacted()
    |> put_change(:superseded_by_id, nil)
    |> put_change(:state_version, 1)
    |> validate_required([
      :project_id,
      :feature_id,
      :run_id,
      :command_id,
      :kind,
      :name,
      :outcome,
      :duration_ms,
      :branch,
      :commit_sha,
      :source,
      :recorded_at,
      :digest
    ])
    |> validate_check_provenance()
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_length(:name, max: @max_name_bytes, count: :bytes)
    |> validate_length(:command, max: @max_command_bytes, count: :bytes)
    |> validate_length(:branch, max: @max_branch_bytes, count: :bytes)
    |> validate_length(:commit_sha, max: @max_commit_bytes, count: :bytes)
    |> validate_length(:artifact_ref, max: @max_artifact_ref_bytes, count: :bytes)
    |> validate_format(:digest, @digest_pattern)
    |> apply_constraints()
  end

  @doc """
  Links one recorded item to the item that replaced it.

  This is the only write an existing row accepts, and it sets one field. A row
  that already names its replacement is refused rather than relinked, so the
  chain a reader follows cannot be rewritten after the fact.
  """
  def supersede_changeset(%__MODULE__{} = evidence, superseded_by_id, expected_state_version) do
    evidence
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_supersedable(superseded_by_id)
    |> put_change(:superseded_by_id, superseded_by_id)
    |> validate_required([:superseded_by_id])
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = evidence) do
    %{
      "id" => evidence.id,
      "project_id" => evidence.project_id,
      "feature_id" => evidence.feature_id,
      "run_id" => evidence.run_id,
      "attempt_id" => evidence.attempt_id,
      "command_id" => evidence.command_id,
      "kind" => evidence.kind,
      "name" => evidence.name,
      "outcome" => evidence.outcome,
      "command" => evidence.command,
      "exit_code" => evidence.exit_code,
      "duration_ms" => evidence.duration_ms,
      "branch" => evidence.branch,
      "commit_sha" => evidence.commit_sha,
      "source" => evidence.source,
      "recorded_at" => DateTime.to_iso8601(evidence.recorded_at),
      "digest" => evidence.digest,
      "redacted" => evidence.redacted,
      "artifact_ref" => evidence.artifact_ref,
      "superseded_by_id" => evidence.superseded_by_id,
      "state_version" => evidence.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_evidence_value}
  def from_value(%{} = value) do
    with true <- value["kind"] in @kinds,
         true <- value["outcome"] in @outcomes,
         true <- value["source"] in @sources,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_integer(value["duration_ms"]) and value["duration_ms"] >= 0,
         true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["feature_id"]) and is_binary(value["run_id"]),
         true <- is_binary(value["name"]) and is_binary(value["branch"]),
         true <- is_binary(value["commit_sha"]) and is_binary(value["digest"]),
         true <- is_boolean(value["redacted"]),
         {:ok, recorded_at, _offset} <- DateTime.from_iso8601(value["recorded_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         feature_id: value["feature_id"],
         run_id: value["run_id"],
         attempt_id: value["attempt_id"],
         command_id: value["command_id"],
         kind: value["kind"],
         name: value["name"],
         outcome: value["outcome"],
         command: value["command"],
         exit_code: value["exit_code"],
         duration_ms: value["duration_ms"],
         branch: value["branch"],
         commit_sha: value["commit_sha"],
         source: value["source"],
         recorded_at: recorded_at,
         digest: value["digest"],
         redacted: value["redacted"],
         artifact_ref: value["artifact_ref"],
         superseded_by_id: value["superseded_by_id"],
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_evidence_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_evidence_value}

  defp put_default_recorded_at(changeset) do
    case get_field(changeset, :recorded_at) do
      nil -> put_change(changeset, :recorded_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp put_default_redacted(changeset) do
    case get_field(changeset, :redacted) do
      nil -> put_change(changeset, :redacted, false)
      _present -> changeset
    end
  end

  # A required check has to say what it ran and how that ended, even when the
  # result is `missing` or `unsupported`: an outcome with no exit provenance is
  # the unsupported completion claim this record exists to replace.
  defp validate_check_provenance(changeset) do
    case get_field(changeset, :kind) do
      "required_check" ->
        changeset
        |> validate_required([:command, :exit_code])
        |> validate_length(:command, min: 1, count: :bytes)

      _other ->
        changeset
    end
  end

  defp validate_expected_version(changeset, expected) do
    if changeset.data.state_version == expected do
      changeset
    else
      add_error(changeset, :state_version, "is stale")
    end
  end

  defp validate_supersedable(changeset, superseded_by_id) do
    cond do
      not is_nil(changeset.data.superseded_by_id) ->
        add_error(changeset, :superseded_by_id, "is already recorded")

      superseded_by_id == changeset.data.id ->
        add_error(changeset, :superseded_by_id, "cannot supersede itself")

      true ->
        changeset
    end
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:state_version, greater_than: 0)
    |> check_constraint(:kind, name: :evidence_kind_allowed)
    |> check_constraint(:outcome, name: :evidence_outcome_allowed)
    |> check_constraint(:source, name: :evidence_source_allowed)
    |> check_constraint(:exit_code, name: :evidence_required_check_provenance)
    |> check_constraint(:duration_ms, name: :evidence_duration_non_negative)
    |> check_constraint(:name, name: :evidence_name_length)
    |> check_constraint(:command, name: :evidence_command_length)
    |> check_constraint(:branch, name: :evidence_branch_length)
    |> check_constraint(:commit_sha, name: :evidence_commit_sha_length)
    |> check_constraint(:artifact_ref, name: :evidence_artifact_ref_length)
    |> check_constraint(:digest, name: :evidence_digest_format)
    |> check_constraint(:superseded_by_id, name: :evidence_supersession_distinct)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:superseded_by_id)
  end
end
