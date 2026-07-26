defmodule SddOrchestrator.Accounts.PersonalWorkspace do
  @moduledoc """
  The one-to-one authenticated profile of a hosted `Workspace`.

  Its id is the common logical workspace id, preserving the stable ownership key
  used by projects, onboarding attempts, and repository connections. The unique
  `account_id` constraint keeps restoration race-safe.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "personal_workspaces" do
    belongs_to :account, SddOrchestrator.Accounts.Account

    belongs_to :workspace, SddOrchestrator.Accounts.Workspace,
      foreign_key: :id,
      define_field: false

    timestamps()
  end

  @doc false
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:id, :account_id])
    |> validate_required([:id, :account_id])
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:id)
    |> foreign_key_constraint(:account_id)
  end
end
