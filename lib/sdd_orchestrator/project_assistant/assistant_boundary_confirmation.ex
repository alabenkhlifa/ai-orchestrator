defmodule SddOrchestrator.ProjectAssistant.AssistantBoundaryConfirmation do
  @moduledoc """
  One private hosted proof that a participant reviewed and confirmed the
  disclosed AI processing boundary for one project.

  Mirrors `ProjectAssistantConversation`'s identity boundary exactly: at most
  one row per `(project_id, account_id)` (`unique_index`), reachable only
  through the acting participant's own re-verified current participation.
  Confirming again after a change replaces the digest, version, and
  confirmation time in place rather than appending a second row — there is
  exactly one current confirmation per participant per project, never a
  history of past ones.

  This schema carries no credential, exact quota, or provider diagnostic: the
  digest is a stable hash of `ProcessingSummary`'s disclosed fields only.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "assistant_boundary_confirmations" do
    field :boundary_digest, :string
    field :boundary_version, :integer
    field :confirmed_at, :utc_datetime

    belongs_to :project, Project
    belongs_to :account, Account

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, [:project_id, :account_id, :boundary_digest, :boundary_version, :confirmed_at])
    |> validate_required([
      :project_id,
      :account_id,
      :boundary_digest,
      :boundary_version,
      :confirmed_at
    ])
    |> validate_length(:boundary_digest, min: 1, max: 255)
    |> validate_number(:boundary_version, greater_than: 0)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:account_id)
    |> unique_constraint([:project_id, :account_id],
      name: :assistant_boundary_confirmations_project_id_account_id_index
    )
    |> check_constraint(:boundary_version,
      name: :assistant_boundary_confirmations_boundary_version_positive
    )
  end

  @doc "Replaces an existing confirmation's digest, version, and confirmation time."
  @spec reconfirm_changeset(t(), map()) :: Ecto.Changeset.t()
  def reconfirm_changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, [:boundary_digest, :boundary_version, :confirmed_at])
    |> validate_required([:boundary_digest, :boundary_version, :confirmed_at])
    |> validate_length(:boundary_digest, min: 1, max: 255)
    |> validate_number(:boundary_version, greater_than: 0)
    |> check_constraint(:boundary_version,
      name: :assistant_boundary_confirmations_boundary_version_positive
    )
  end
end
