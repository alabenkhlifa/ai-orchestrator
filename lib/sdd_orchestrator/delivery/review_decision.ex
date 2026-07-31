defmodule SddOrchestrator.Delivery.ReviewDecision do
  @moduledoc """
  One person's final verdict on the exact commit an attempt proved.

  A verdict is written once and never again. There is no update changeset and no
  supersession chain, and the database refuses `UPDATE` outright, because a
  rejection that could later be edited into an approval would make the feature's
  history a claim rather than a record. A reviewer who changes their mind is
  reviewing a *later* attempt, which is a different decision about a different
  commit.

  One attempt has one decision. The unique binding of run and attempt is what
  makes a double-submitted approval a refusal at the store instead of two
  verdicts about the same proof, whichever process asks.

  Feedback is paired with the outcome in both directions, in the changeset and
  again at the database. A rejection without feedback leaves the next attempt
  nothing to act on, and an approval carrying feedback is a record that reads as
  a complaint about work that was accepted.

  What is kept of the reviewer is an account reference. Display names resolve
  from current participation when a screen renders, so a later rename or
  departure is reflected rather than frozen here, and no participant email
  exists anywhere on this path.

  The branch and commit are copied from the recorded verified completion rather
  than from the run, so a decision names exactly what was proved instead of
  whatever the branch has moved on to. The preview reference is the deployment
  the reviewer could have opened; a preview is a convenience and never a verdict,
  so its absence is ordinary and blocks nothing.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Delivery.{AgentRun, Feature, RunAttempt}
  alias SddOrchestrator.Projects.Project

  @decisions ~w(approved rejected)

  @max_feedback_bytes 4_000
  @max_branch_bytes 200
  @max_commit_bytes 64

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "review_decisions" do
    field :decision, :string
    field :feedback, :string
    field :branch, :string
    field :commit_sha, :string
    field :decided_at, :utc_datetime_usec
    field :state_version, :integer, default: 1

    # A plain reference rather than an association: a preview is a convenience
    # and never a verdict, so it must not be able to block a governed decision
    # from being written, kept, or released — and a device-authoritative
    # project's preview does not live in the hosted database at all.
    field :preview_deployment_id, :binary_id

    belongs_to :project, Project
    belongs_to :feature, Feature
    belongs_to :run, AgentRun
    belongs_to :attempt, RunAttempt
    belongs_to :reviewer_account, Account

    timestamps()
  end

  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @spec max_feedback_bytes() :: pos_integer()
  def max_feedback_bytes, do: @max_feedback_bytes

  @doc "Reports whether one verdict accepted the work."
  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{decision: "approved"}), do: true
  def approved?(%__MODULE__{}), do: false

  @doc "Reports whether one verdict sent the work back."
  @spec rejected?(t()) :: boolean()
  def rejected?(%__MODULE__{decision: "rejected"}), do: true
  def rejected?(%__MODULE__{}), do: false

  @doc """
  Records one verdict. There is deliberately no update changeset.

  The trigger behind this table rejects every later change, so nothing built
  here can be edited afterwards by any caller, migration, or console session.
  """
  def record_changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :decision,
      :feedback,
      :reviewer_account_id,
      :branch,
      :commit_sha,
      :preview_deployment_id,
      :decided_at
    ])
    |> put_default_decided_at()
    |> put_change(:state_version, 1)
    |> validate_required([
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :decision,
      :reviewer_account_id,
      :branch,
      :commit_sha,
      :decided_at
    ])
    |> apply_shared_rules()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = decision) do
    %{
      "id" => decision.id,
      "project_id" => decision.project_id,
      "feature_id" => decision.feature_id,
      "run_id" => decision.run_id,
      "attempt_id" => decision.attempt_id,
      "decision" => decision.decision,
      "feedback" => decision.feedback,
      "reviewer_account_id" => decision.reviewer_account_id,
      "branch" => decision.branch,
      "commit_sha" => decision.commit_sha,
      "preview_deployment_id" => decision.preview_deployment_id,
      "decided_at" => encode_time(decision.decided_at),
      "state_version" => decision.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_review_decision_value}
  def from_value(%{} = value) do
    with true <- value["decision"] in @decisions,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["feature_id"]) and is_binary(value["run_id"]),
         true <- is_binary(value["attempt_id"]) and is_binary(value["reviewer_account_id"]),
         true <- is_binary(value["branch"]) and is_binary(value["commit_sha"]),
         true <- paired_feedback?(value["decision"], value["feedback"]),
         {:ok, decided_at} <- decode_time(value["decided_at"]),
         true <- not is_nil(decided_at) do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         feature_id: value["feature_id"],
         run_id: value["run_id"],
         attempt_id: value["attempt_id"],
         decision: value["decision"],
         feedback: value["feedback"],
         reviewer_account_id: value["reviewer_account_id"],
         branch: value["branch"],
         commit_sha: value["commit_sha"],
         preview_deployment_id: value["preview_deployment_id"],
         decided_at: decided_at,
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_review_decision_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_review_decision_value}

  @doc """
  Reports whether one outcome and one feedback text belong together.

  Exposed so a caller can refuse a rejection with nothing to act on before it
  builds anything, rather than discovering it as a changeset error.
  """
  @spec paired_feedback?(term(), term()) :: boolean()
  def paired_feedback?("approved", feedback), do: is_nil(feedback)

  def paired_feedback?("rejected", feedback) when is_binary(feedback),
    do: String.trim(feedback) != "" and byte_size(feedback) <= @max_feedback_bytes

  def paired_feedback?(_decision, _feedback), do: false

  defp put_default_decided_at(changeset) do
    case get_field(changeset, :decided_at) do
      nil -> put_change(changeset, :decided_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp validate_feedback_pairing(changeset) do
    decision = get_field(changeset, :decision)
    feedback = get_field(changeset, :feedback)

    cond do
      decision not in @decisions ->
        changeset

      paired_feedback?(decision, feedback) ->
        changeset

      decision == "approved" ->
        add_error(changeset, :feedback, "is not allowed for an approval")

      true ->
        add_error(changeset, :feedback, "is required for a rejection")
    end
  end

  defp apply_shared_rules(changeset) do
    changeset
    |> validate_inclusion(:decision, @decisions)
    |> validate_number(:state_version, greater_than: 0)
    |> validate_length(:feedback, max: @max_feedback_bytes, count: :bytes)
    |> validate_length(:branch, max: @max_branch_bytes, count: :bytes)
    |> validate_length(:commit_sha, max: @max_commit_bytes, count: :bytes)
    |> validate_feedback_pairing()
    |> check_constraint(:decision, name: :review_decisions_decision_allowed)
    |> check_constraint(:feedback, name: :review_decisions_feedback_pairing)
    |> check_constraint(:feedback, name: :review_decisions_feedback_length)
    |> check_constraint(:branch, name: :review_decisions_branch_length)
    |> check_constraint(:commit_sha, name: :review_decisions_commit_sha_length)
    |> check_constraint(:state_version, name: :review_decisions_state_version_positive)
    |> unique_constraint([:run_id, :attempt_id], name: :review_decisions_attempt_index)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:reviewer_account_id)
  end

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp decode_time(nil), do: {:ok, nil}

  defp decode_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp decode_time(_value), do: :error
end
