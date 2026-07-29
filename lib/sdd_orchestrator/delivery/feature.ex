defmodule SddOrchestrator.Delivery.Feature do
  @moduledoc """
  One project-scoped feature and its place in the delivery lifecycle.

  A feature moves between the five board columns only through the legal
  transitions recorded here, each applied against an expected state version. A
  direct column assignment is not expressible: there is no setter, only
  `transition_changeset/4`, so a dragged card or a stale client cannot bypass a
  workflow gate.

  The state version is enforced twice: the caller's expected version must match
  the loaded record, and the update itself is filtered on that version, so a row
  that moved between load and write is rejected rather than overwritten.

  `Blocked` and `Failed` are statuses, not columns. A feature carrying one stays
  in `In development`, which both the changeset and a database constraint
  enforce.

  Identity is stored as account references. Display names are resolved from the
  participation boundary at render time, so a rename or a departure changes how
  a feature is labelled without rewriting its history.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Projects.Project

  @columns ~w(draft ready_for_development in_development ready_for_review done)
  @statuses ~w(none blocked failed)
  @max_title_bytes 200

  # The complete legal transition table. Anything absent here is rejected,
  # including a move back out of `Done`.
  @transitions %{
    "draft" => ~w(ready_for_development),
    "ready_for_development" => ~w(draft in_development),
    "in_development" => ~w(draft ready_for_development ready_for_review),
    "ready_for_review" => ~w(in_development done),
    "done" => []
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "features" do
    field :title, :string
    field :lifecycle_column, :string, default: "draft"
    field :status, :string, default: "none"
    field :state_version, :integer, default: 1

    belongs_to :project, Project
    belongs_to :creator_account, Account
    belongs_to :assigned_account, Account

    timestamps()
  end

  @spec columns() :: [String.t()]
  def columns, do: @columns

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions

  @spec legal_transition?(String.t(), String.t()) :: boolean()
  def legal_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "Creates one feature in `Draft` for its recorded creator."
  def create_changeset(feature, attrs) do
    feature
    |> cast(attrs, [:project_id, :title, :creator_account_id, :assigned_account_id])
    |> put_change(:lifecycle_column, "draft")
    |> put_change(:status, "none")
    |> put_change(:state_version, 1)
    |> validate_required([:project_id, :title, :creator_account_id])
    |> validate_title()
    |> apply_constraints()
  end

  @doc """
  Applies one legal transition against the caller's expected state version.

  A move that is not in the transition table, or that is offered against a
  superseded state version, produces an errored changeset rather than a
  silently applied change.
  """
  def transition_changeset(%__MODULE__{} = feature, to, expected_state_version, opts \\ []) do
    feature
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_transition(to)
    |> put_change(:lifecycle_column, to)
    |> put_change(:status, Keyword.get(opts, :status, "none"))
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc """
  Records a visible status without moving the feature to another column.
  """
  def status_changeset(%__MODULE__{} = feature, status, expected_state_version) do
    feature
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> put_change(:status, status)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc "Sets or clears the optional assigned participant."
  def assignment_changeset(%__MODULE__{} = feature, account_id, expected_state_version) do
    feature
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> put_change(:assigned_account_id, account_id)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc """
  The device-adapter value shape.

  The worker-owned device store holds the same feature as a plain value with no
  Ecto or hosted-database dependency, so both adapters agree on one shape.
  """
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = feature) do
    %{
      "id" => feature.id,
      "project_id" => feature.project_id,
      "title" => feature.title,
      "creator_account_id" => feature.creator_account_id,
      "assigned_account_id" => feature.assigned_account_id,
      "lifecycle_column" => feature.lifecycle_column,
      "status" => feature.status,
      "state_version" => feature.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_feature_value}
  def from_value(%{} = value) do
    with true <- value["lifecycle_column"] in @columns,
         true <- value["status"] in @statuses,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["title"]) do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         title: value["title"],
         creator_account_id: value["creator_account_id"],
         assigned_account_id: value["assigned_account_id"],
         lifecycle_column: value["lifecycle_column"],
         status: value["status"],
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_feature_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_feature_value}

  defp validate_expected_version(changeset, expected) do
    if changeset.data.state_version == expected do
      changeset
    else
      add_error(changeset, :state_version, "is stale")
    end
  end

  defp validate_transition(changeset, to) do
    from = changeset.data.lifecycle_column

    if legal_transition?(from, to) do
      changeset
    else
      add_error(changeset, :lifecycle_column, "cannot move from #{from} to #{to}")
    end
  end

  defp validate_title(changeset) do
    case fetch_change(changeset, :title) do
      {:ok, title} when is_binary(title) -> put_trimmed_title(changeset, String.trim(title))
      _other -> changeset
    end
  end

  defp put_trimmed_title(changeset, "") do
    changeset |> put_change(:title, "") |> add_error(:title, "can't be blank")
  end

  defp put_trimmed_title(changeset, trimmed) do
    changeset
    |> put_change(:title, trimmed)
    |> validate_length(:title, max: @max_title_bytes, count: :bytes)
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:lifecycle_column, @columns)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:state_version, greater_than: 0)
    |> validate_status_placement()
    |> check_constraint(:lifecycle_column, name: :features_lifecycle_column_allowed)
    |> check_constraint(:status, name: :features_status_placement)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:creator_account_id)
    |> foreign_key_constraint(:assigned_account_id)
  end

  defp validate_status_placement(changeset) do
    status = get_field(changeset, :status)
    column = get_field(changeset, :lifecycle_column)

    if status == "none" or column == "in_development" do
      changeset
    else
      add_error(changeset, :status, "is only visible while a feature is in development")
    end
  end
end
