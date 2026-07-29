defmodule SddOrchestrator.Delivery.BlockingQuestion do
  @moduledoc """
  One focused product decision that pauses a run without losing its work.

  A question is the durable form of "the agent reached something it must not
  decide alone". It carries the branch, the workspace, and the checkpoint the
  asking attempt had reached, because an answer has to continue accepted work
  rather than start it again — a provider thread is an optimization, never the
  thing recovery depends on.

  At most one question of a run is open at a time. That is enforced by a partial
  unique index rather than by callers behaving, so a redelivered event, a
  reconnecting worker, or an agent that keeps talking cannot leave a reader with
  two competing decisions.

  Blocking is a status, never a column: the feature this question belongs to
  stays in `In development` for the whole time it is open.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.{AgentRun, Feature, RunAttempt}
  alias SddOrchestrator.Projects.Project

  @states ~w(open answered superseded)
  @resolved_states ~w(answered superseded)

  @max_question_bytes 2_000
  @max_context_bytes 4_000
  @max_branch_bytes 200
  @max_workspace_bytes 1_000
  @max_checkpoint_bytes 4_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "blocking_questions" do
    field :question, :string
    field :context, :string
    field :state, :string, default: "open"
    field :checkpoint, :map, default: %{}
    field :branch, :string
    field :workspace_path, :string
    field :asked_at, :utc_datetime_usec
    field :state_version, :integer, default: 1

    belongs_to :project, Project
    belongs_to :feature, Feature
    belongs_to :run, AgentRun
    belongs_to :attempt, RunAttempt

    timestamps()
  end

  @spec states() :: [String.t()]
  def states, do: @states

  @spec resolved_states() :: [String.t()]
  def resolved_states, do: @resolved_states

  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{state: state}), do: state == "open"

  @spec max_question_bytes() :: pos_integer()
  def max_question_bytes, do: @max_question_bytes

  @spec max_context_bytes() :: pos_integer()
  def max_context_bytes, do: @max_context_bytes

  @spec max_checkpoint_bytes() :: pos_integer()
  def max_checkpoint_bytes, do: @max_checkpoint_bytes

  @doc """
  Asks one open question against the state the attempt had reached.

  The branch is supplied by the run rather than by the worker, so a question
  can never claim work happened somewhere the run does not own.
  """
  def ask_changeset(question, attrs) do
    question
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :question,
      :context,
      :checkpoint,
      :branch,
      :workspace_path,
      :asked_at
    ])
    |> put_default_asked_at()
    |> put_change(:state, "open")
    |> put_change(:state_version, 1)
    |> validate_required([
      :project_id,
      :feature_id,
      :run_id,
      :question,
      :branch,
      :workspace_path,
      :asked_at
    ])
    |> validate_question()
    |> validate_length(:context, max: @max_context_bytes, count: :bytes)
    |> validate_length(:branch, max: @max_branch_bytes, count: :bytes)
    |> validate_length(:workspace_path, max: @max_workspace_bytes, count: :bytes)
    |> validate_checkpoint()
    |> apply_constraints()
  end

  @doc """
  Closes an open question against the caller's expected state version.

  Only an open question can be resolved, so an answer offered twice moves
  nothing the second time.
  """
  def resolve_changeset(%__MODULE__{} = question, to, expected_state_version) do
    question
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_resolution(to)
    |> put_change(:state, to)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = question) do
    %{
      "id" => question.id,
      "project_id" => question.project_id,
      "feature_id" => question.feature_id,
      "run_id" => question.run_id,
      "attempt_id" => question.attempt_id,
      "question" => question.question,
      "context" => question.context,
      "state" => question.state,
      "checkpoint" => question.checkpoint,
      "branch" => question.branch,
      "workspace_path" => question.workspace_path,
      "asked_at" => DateTime.to_iso8601(question.asked_at),
      "state_version" => question.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_question_value}
  def from_value(%{} = value) do
    with true <- value["state"] in @states,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["feature_id"]) and is_binary(value["run_id"]),
         true <- is_binary(value["question"]) and is_binary(value["branch"]),
         true <- is_binary(value["workspace_path"]),
         true <- is_map(value["checkpoint"] || %{}),
         {:ok, asked_at, _offset} <- DateTime.from_iso8601(value["asked_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         feature_id: value["feature_id"],
         run_id: value["run_id"],
         attempt_id: value["attempt_id"],
         question: value["question"],
         context: value["context"],
         state: value["state"],
         checkpoint: value["checkpoint"] || %{},
         branch: value["branch"],
         workspace_path: value["workspace_path"],
         asked_at: asked_at,
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_question_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_question_value}

  defp put_default_asked_at(changeset) do
    case get_field(changeset, :asked_at) do
      nil -> put_change(changeset, :asked_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  # A blank question would pause a run without telling anyone what to decide,
  # which is the one thing a blocking question exists to prevent.
  defp validate_question(changeset) do
    case fetch_change(changeset, :question) do
      {:ok, question} when is_binary(question) -> put_trimmed_question(changeset, question)
      _other -> changeset
    end
  end

  defp put_trimmed_question(changeset, question) do
    case String.trim(question) do
      "" ->
        add_error(changeset, :question, "can't be blank")

      trimmed ->
        changeset
        |> put_change(:question, trimmed)
        |> validate_length(:question, max: @max_question_bytes, count: :bytes)
    end
  end

  # The checkpoint is opaque worker state, so its content is not interpreted
  # here — only its size, which is what stops a resume aid from becoming a
  # transcript.
  defp validate_checkpoint(changeset) do
    case get_field(changeset, :checkpoint) do
      nil -> put_change(changeset, :checkpoint, %{})
      checkpoint when is_map(checkpoint) -> validate_checkpoint_size(changeset, checkpoint)
      _other -> add_error(changeset, :checkpoint, "must be a map")
    end
  end

  defp validate_checkpoint_size(changeset, checkpoint) do
    if checkpoint_bytes(checkpoint) > @max_checkpoint_bytes do
      add_error(changeset, :checkpoint, "is larger than #{@max_checkpoint_bytes} bytes")
    else
      changeset
    end
  end

  defp checkpoint_bytes(checkpoint) do
    checkpoint |> Jason.encode!() |> byte_size()
  rescue
    Protocol.UndefinedError -> @max_checkpoint_bytes + 1
  end

  defp validate_expected_version(changeset, expected) do
    if changeset.data.state_version == expected do
      changeset
    else
      add_error(changeset, :state_version, "is stale")
    end
  end

  defp validate_resolution(changeset, to) do
    if changeset.data.state == "open" and to in @resolved_states do
      changeset
    else
      add_error(changeset, :state, "cannot move from #{changeset.data.state} to #{to}")
    end
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> validate_number(:state_version, greater_than: 0)
    |> check_constraint(:state, name: :blocking_questions_state_allowed)
    |> check_constraint(:question, name: :blocking_questions_question_length)
    |> check_constraint(:context, name: :blocking_questions_context_length)
    |> check_constraint(:branch, name: :blocking_questions_branch_length)
    |> check_constraint(:workspace_path, name: :blocking_questions_workspace_path_length)
    |> unique_constraint(:state, name: :blocking_questions_one_open_question)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:attempt_id)
  end
end
