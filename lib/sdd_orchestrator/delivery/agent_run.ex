defmodule SddOrchestrator.Delivery.AgentRun do
  @moduledoc """
  One authorized feature-delivery lifecycle.

  A run is the durable thing that survives everything an execution can do to
  it. It is created once for one feature, owns exactly one isolated branch for
  its whole lifetime, and holds ordered attempts until it is approved,
  canceled, or cleaned up. Retry, a blocking answer, and a review rejection all
  continue the same run; only cancellation is terminal, and a later start
  creates a different run with a different branch.

  Specification revisions belong to the shared specification store, so they are
  referenced here by identity and digest. A device-authoritative project's
  revisions never exist in this database, and this schema must not become a
  second copy of them.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Delivery.Feature
  alias SddOrchestrator.Projects.Project

  @states ~w(pending running blocked failed canceled completed)
  @terminal_states ~w(failed canceled completed)

  # The legal run transition table. Anything absent is rejected, including any
  # move out of a terminal state.
  @transitions %{
    "pending" => ~w(running canceled failed),
    "running" => ~w(blocked failed canceled completed),
    "blocked" => ~w(running failed canceled),
    "failed" => ~w(running canceled),
    "canceled" => [],
    "completed" => []
  }

  @max_branch_bytes 200
  @max_slice_bytes 200
  @max_reason_bytes 200

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "agent_runs" do
    field :starting_revision_id, :string
    field :starting_revision_digest, :string
    field :effective_revision_id, :string
    field :effective_revision_digest, :string
    field :approved_slice, :string
    field :branch, :string
    field :state, :string, default: "pending"
    field :failure_reason, :string
    field :current_attempt_number, :integer, default: 0
    field :state_version, :integer, default: 1

    belongs_to :project, Project
    belongs_to :feature, Feature
    belongs_to :initiator_account, Account

    timestamps()
  end

  @spec states() :: [String.t()]
  def states, do: @states

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions

  @spec legal_transition?(String.t(), String.t()) :: boolean()
  def legal_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @doc """
  Creates one run in `pending` against its immutable starting revision.

  The effective revision starts equal to the starting revision; an accepted
  blocking answer is what later moves it forward.
  """
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :initiator_account_id,
      :starting_revision_id,
      :starting_revision_digest,
      :approved_slice,
      :branch
    ])
    |> put_effective_from_starting()
    |> put_change(:state, "pending")
    |> put_change(:current_attempt_number, 0)
    |> put_change(:state_version, 1)
    |> validate_required([
      :project_id,
      :feature_id,
      :starting_revision_id,
      :starting_revision_digest,
      :approved_slice,
      :branch
    ])
    |> validate_length(:branch, max: @max_branch_bytes, count: :bytes)
    |> validate_length(:approved_slice, max: @max_slice_bytes, count: :bytes)
    |> apply_constraints()
  end

  @doc """
  Applies one legal run transition against the caller's expected state version.

  `:failure_reason` is accepted only for a move into `failed`; every other
  transition clears it, so a recovered run never keeps a stale reason.
  """
  def transition_changeset(%__MODULE__{} = run, to, expected_state_version, opts \\ []) do
    run
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_transition(to)
    |> put_change(:state, to)
    |> put_failure_reason(to, Keyword.get(opts, :failure_reason))
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc """
  Records the next ordered attempt number for this run.

  The number only ever moves forward, which is what makes an attempt ordering
  gap visible instead of silently reusing a number.
  """
  def attempt_advance_changeset(%__MODULE__{} = run, attempt_number, expected_state_version) do
    run
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> put_change(:current_attempt_number, attempt_number)
    |> validate_attempt_advance(attempt_number)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc """
  Moves the run onto a newer effective specification revision.

  Used when an accepted blocking answer appends a revision the next attempt
  must work from. The immutable starting revision is never rewritten.
  """
  def effective_revision_changeset(
        %__MODULE__{} = run,
        revision_id,
        revision_digest,
        expected_state_version
      ) do
    run
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> put_change(:effective_revision_id, revision_id)
    |> put_change(:effective_revision_digest, revision_digest)
    |> validate_required([:effective_revision_id, :effective_revision_digest])
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = run) do
    %{
      "id" => run.id,
      "project_id" => run.project_id,
      "feature_id" => run.feature_id,
      "initiator_account_id" => run.initiator_account_id,
      "starting_revision_id" => run.starting_revision_id,
      "starting_revision_digest" => run.starting_revision_digest,
      "effective_revision_id" => run.effective_revision_id,
      "effective_revision_digest" => run.effective_revision_digest,
      "approved_slice" => run.approved_slice,
      "branch" => run.branch,
      "state" => run.state,
      "failure_reason" => run.failure_reason,
      "current_attempt_number" => run.current_attempt_number,
      "state_version" => run.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_run_value}
  def from_value(%{} = value) do
    with true <- value["state"] in @states,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_integer(value["current_attempt_number"]),
         true <- value["current_attempt_number"] >= 0,
         true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["feature_id"]) and is_binary(value["branch"]) do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         feature_id: value["feature_id"],
         initiator_account_id: value["initiator_account_id"],
         starting_revision_id: value["starting_revision_id"],
         starting_revision_digest: value["starting_revision_digest"],
         effective_revision_id: value["effective_revision_id"],
         effective_revision_digest: value["effective_revision_digest"],
         approved_slice: value["approved_slice"],
         branch: value["branch"],
         state: value["state"],
         failure_reason: value["failure_reason"],
         current_attempt_number: value["current_attempt_number"],
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_run_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_run_value}

  defp put_effective_from_starting(changeset) do
    changeset
    |> put_change(:effective_revision_id, get_field(changeset, :starting_revision_id))
    |> put_change(:effective_revision_digest, get_field(changeset, :starting_revision_digest))
  end

  defp put_failure_reason(changeset, "failed", reason) when is_binary(reason) do
    changeset
    |> put_change(:failure_reason, reason)
    |> validate_length(:failure_reason, max: @max_reason_bytes, count: :bytes)
  end

  defp put_failure_reason(changeset, "failed", _reason),
    do: add_error(changeset, :failure_reason, "is required for a failed run")

  defp put_failure_reason(changeset, _to, _reason),
    do: put_change(changeset, :failure_reason, nil)

  defp validate_expected_version(changeset, expected) do
    if changeset.data.state_version == expected do
      changeset
    else
      add_error(changeset, :state_version, "is stale")
    end
  end

  defp validate_transition(changeset, to) do
    from = changeset.data.state

    if legal_transition?(from, to) do
      changeset
    else
      add_error(changeset, :state, "cannot move from #{from} to #{to}")
    end
  end

  defp validate_attempt_advance(changeset, attempt_number) do
    if is_integer(attempt_number) and attempt_number > changeset.data.current_attempt_number do
      changeset
    else
      add_error(changeset, :current_attempt_number, "must move forward")
    end
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> validate_number(:state_version, greater_than: 0)
    |> validate_number(:current_attempt_number, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :agent_runs_state_allowed)
    |> check_constraint(:failure_reason, name: :agent_runs_failure_reason_placement)
    |> unique_constraint([:project_id, :branch])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
    |> foreign_key_constraint(:initiator_account_id)
  end
end
