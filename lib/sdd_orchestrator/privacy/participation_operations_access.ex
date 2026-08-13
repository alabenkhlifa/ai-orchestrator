defmodule SddOrchestrator.Privacy.ParticipationOperationsAccess do
  @moduledoc """
  The minimized operations metadata view AC-02 requires for the "operations
  actor" case (specs/26 Task 2).

  No such view existed anywhere in the codebase before this task: the owner
  and participant views are already served by
  `SddOrchestrator.Participation.Boundary` and
  `SddOrchestrator.Participation.members/3` (Slice 08), which this task
  consumes rather than duplicates. This module is the genuinely new
  closed shaping policy for the operations recipient category.

  ## Field boundary

  Business Rules limit operations access to "necessary minimized service and
  security metadata," and AC-02 forbids disclosing content or identity
  existence. The Task 1 `SddOrchestrator.Privacy.ParticipationProcessingInventory`
  classifies two entities' fields `:minimized_operations`:

    * `ParticipationEmailDelivery` — every field (`event_type`, `status`,
      `failure_code`, and timestamps are its diagnostic evidence).
    * `ProjectInvitation.email_digest/token_digest/token_salt` — pure
      credential-verification mechanics.

  That classification is a *ceiling*, not a shaping policy by itself: it also
  covers `ParticipationEmailDelivery.recipient_address`, which is a real
  email address, and the three `ProjectInvitation` fields above are
  invitation credential material. Both are explicitly forbidden from an
  operations view by this specification's own Business Rules ("no display
  name, no email, no invitation credential digest, no free-text content"),
  even though the inventory happens to classify them under the same
  recipient category. `allowed_fields/0` is therefore the intersection of
  "classified `:minimized_operations`" and "not an email, display name, or
  credential" — never the full inventory set.

  ## Project scope

  `ParticipationEmailDelivery` carries no `project_id` of its own; it is
  addressed only by `subject_ref`, which names either the `ProjectInvitation`
  or the `ParticipationRevocation` the delivery attempt reports on. Scoping
  to one project therefore joins through those two owning records' `id`
  rather than through any presentation field.
  """

  import Ecto.Query

  alias SddOrchestrator.Participation.{
    ParticipationEmailDelivery,
    ParticipationRevocation,
    ProjectInvitation
  }

  alias SddOrchestrator.Privacy.ParticipationProcessingInventory
  alias SddOrchestrator.Repo

  @allowed_fields ~w(
    id
    event_type
    subject_ref
    event_version
    status
    failure_code
    attempted_at
    delivered_at
  )a

  @type entry :: %{
          id: Ecto.UUID.t(),
          event_type: String.t(),
          subject_ref: Ecto.UUID.t(),
          event_version: pos_integer(),
          status: String.t(),
          failure_code: String.t() | nil,
          attempted_at: DateTime.t(),
          delivered_at: DateTime.t() | nil
        }

  @doc "The closed field set this view may ever surface."
  @spec allowed_fields() :: [atom()]
  def allowed_fields, do: @allowed_fields

  @doc """
  Every `{entity, field}` the Task 1 processing inventory classifies
  `:minimized_operations`.

  This is the upper bound `allowed_fields/0` is checked against: this view
  must never surface a field the inventory has not already approved for the
  operations recipient, even though it deliberately surfaces fewer fields
  than this full set (see moduledoc).
  """
  @spec inventory_minimized_operations_fields() :: [{atom(), atom()}]
  def inventory_minimized_operations_fields do
    for %{entity: entity, field: field, recipient_category: :minimized_operations} <-
          ParticipationProcessingInventory.records(),
        do: {entity, field}
  end

  @doc """
  Returns the minimized service and security metadata for one project's
  email-delivery attempts: no display name, no email, no invitation
  credential, no free-text content.

  Scoped to the project through its invitations and departure handoffs
  alone. An unknown or empty project returns an empty list rather than a
  distinguishing error, so this view discloses no project or content
  existence beyond what the caller already supplied.
  """
  @spec metadata_for_project(Ecto.UUID.t()) :: [entry()]
  def metadata_for_project(project_id) do
    subject_ids = invitation_ids(project_id) ++ revocation_ids(project_id)

    ParticipationEmailDelivery
    |> where([d], d.subject_ref in ^subject_ids)
    |> order_by([d], desc: d.attempted_at, desc: d.id)
    |> select([d], %{
      id: d.id,
      event_type: d.event_type,
      subject_ref: d.subject_ref,
      event_version: d.event_version,
      status: d.status,
      failure_code: d.failure_code,
      attempted_at: d.attempted_at,
      delivered_at: d.delivered_at
    })
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  defp invitation_ids(project_id) do
    ProjectInvitation
    |> where([i], i.project_id == ^project_id)
    |> select([i], i.id)
    |> Repo.all()
  end

  defp revocation_ids(project_id) do
    ParticipationRevocation
    |> where([r], r.project_id == ^project_id)
    |> select([r], r.id)
    |> Repo.all()
  end
end
