defmodule SddOrchestrator.Accounts.PersonalWorkspace do
  @moduledoc """
  The one-to-one account ownership boundary for projects and repository
  connections. Every account has exactly one personal workspace; the unique
  `account_id` constraint makes get-or-create restoration race-safe.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "personal_workspaces" do
    belongs_to :account, SddOrchestrator.Accounts.Account

    timestamps()
  end

  @doc false
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:account_id])
    |> validate_required([:account_id])
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:account_id)
  end
end
