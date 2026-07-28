defmodule SddOrchestrator.IdentityLinking.WorkspaceMergeRecord do
  @moduledoc """
  The minimal, inaccessible record that replaces an absorbed workspace after a
  committed merge.

  It retains only the six approved fields and no other personal data, so it cannot
  reconstruct the absorbed workspace. It is personal data on a legitimate-interest
  basis (idempotency, security audit, takeover prevention, verified support, and
  rights handling), is never joined to analytics, and is deleted at `delete_after`
  by the retention pruner or by rights erasure of the surviving account. The final
  lawful-basis confirmation and exact retention are a release-gate item.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(completed)

  @primary_key {:merge_event_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "workspace_merge_records" do
    field :source_workspace_id, :binary_id
    field :surviving_workspace_id, :binary_id
    field :status, :string
    field :completed_at, :utc_datetime
    field :delete_after, :utc_datetime
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :merge_event_id,
      :source_workspace_id,
      :surviving_workspace_id,
      :status,
      :completed_at,
      :delete_after
    ])
    |> validate_required([
      :merge_event_id,
      :source_workspace_id,
      :surviving_workspace_id,
      :status,
      :completed_at,
      :delete_after
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:merge_event_id, name: :workspace_merge_records_pkey)
  end
end
