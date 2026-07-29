defmodule SddOrchestrator.Participation.ProjectMemberProfile do
  @moduledoc """
  The project-specific presentation profile of the immutable owner or one
  participant.

  Authorization identity lives in the project ownership boundary and
  `ProjectParticipant`. This record holds only the accepted display spelling,
  its project comparison key, the stable account reference kept while the label
  still identifies a person, and the anonymization state that removes that link
  without erasing stable project history.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Participation.DisplayName
  alias SddOrchestrator.Projects.Project

  @roles ~w(owner participant)
  @states ~w(active historical anonymized)
  @anonymous_label "Former participant"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "project_member_profiles" do
    field :role, :string
    field :state, :string, default: "active"
    field :display_name, :string
    field :display_name_key, :string
    field :anonymized_at, :utc_datetime

    belongs_to :project, Project
    belongs_to :account, Account

    timestamps()
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec states() :: [String.t()]
  def states, do: @states

  @spec anonymous_label() :: String.t()
  def anonymous_label, do: @anonymous_label

  @doc "Creates or replaces one current project label for a member."
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:project_id, :account_id, :role, :display_name])
    |> put_change(:state, "active")
    |> put_display_name()
    |> validate_required([:project_id, :account_id, :role, :display_name, :display_name_key])
    |> validate_inclusion(:role, @roles)
    |> apply_constraints()
  end

  @doc "Renames only the label, preserving the member's stable identity and role."
  def rename_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:display_name])
    |> put_display_name()
    |> validate_required([:display_name, :display_name_key])
    |> apply_constraints()
  end

  @doc """
  Preserves the last accepted label as non-interactive historical attribution.
  """
  def historical_changeset(profile) do
    profile
    |> change(%{state: "historical"})
    |> apply_constraints()
  end

  @doc """
  Removes the account link and replaces the label once continued identification
  is no longer necessary for project accountability.
  """
  def anonymization_changeset(profile, anonymized_at \\ nil) do
    profile
    |> change(%{
      state: "anonymized",
      account_id: nil,
      display_name: @anonymous_label,
      display_name_key: DisplayName.key(@anonymous_label),
      anonymized_at: anonymized_at || now()
    })
    |> apply_constraints()
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: "active"}), do: true
  def active?(%__MODULE__{}), do: false

  defp put_display_name(changeset) do
    case fetch_change(changeset, :display_name) do
      {:ok, value} -> apply_display_name(changeset, DisplayName.normalize(value))
      :error -> changeset
    end
  end

  defp apply_display_name(changeset, {:ok, normalized}) do
    changeset
    |> put_change(:display_name, normalized.display_name)
    |> put_change(:display_name_key, normalized.display_name_key)
  end

  defp apply_display_name(changeset, {:error, :invalid_display_name}) do
    add_error(changeset, :display_name, "is not an available project label")
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:display_name,
      name: :project_member_profiles_active_display_name_index,
      message: "is already used in this project"
    )
    |> unique_constraint(:account_id,
      name: :project_member_profiles_account_index,
      message: "already has a profile in this project"
    )
    |> check_constraint(:role, name: :project_member_profiles_role_allowed)
    |> check_constraint(:state, name: :project_member_profiles_anonymized_shape)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:account_id)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
