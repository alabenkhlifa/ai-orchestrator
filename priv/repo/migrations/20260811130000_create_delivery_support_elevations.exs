defmodule SddOrchestrator.Repo.Migrations.CreateDeliverySupportElevations do
  use Ecto.Migration

  # specs/18 Task 2 (AC-03): the one exceptional-support elevation grant. Support
  # and operations access to guided-delivery content is disabled by default —
  # every grant defaults to `scope = 'metadata'`, which
  # `SddOrchestrator.Privacy.DeliverySupportAccess.authorize_content_read/2`
  # never treats as authorizing a content read. Elevating to `scope = 'content'`
  # requires an explicit purpose from the closed vocabulary below, one project,
  # and a bounded expiry — never an unbounded or missing one.
  def change do
    create table(:delivery_support_elevations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Nilified rather than cascaded: the elevation is audit evidence of what
      # access was granted and stays on record even after the operations
      # account itself is removed.
      add :operations_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      # Scoped to exactly one project's incident, never a standing cross-project
      # grant. Cascades with the project because a deleted project leaves
      # nothing left to elevate access to.
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :purpose, :string, null: false
      add :scope, :string, null: false, default: "metadata"

      add :issued_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :revoked_at, :utc_datetime_usec
      add :revoked_by_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:delivery_support_elevations, [:project_id])
    create index(:delivery_support_elevations, [:operations_account_id])
    create index(:delivery_support_elevations, [:expires_at])

    create constraint(
             :delivery_support_elevations,
             :delivery_support_elevations_purpose_allowed,
             check: "purpose IN ('incident_diagnosis', 'security_investigation')"
           )

    create constraint(
             :delivery_support_elevations,
             :delivery_support_elevations_scope_allowed,
             check: "scope IN ('metadata', 'content')"
           )

    # Time-bounded, not merely present: an elevation must expire after it is
    # issued and within 24 hours of issue, so "least privilege" is a property the
    # store enforces rather than a caller convention.
    create constraint(
             :delivery_support_elevations,
             :delivery_support_elevations_bounded_expiry,
             check:
               "expires_at > issued_at AND extract(epoch from (expires_at - issued_at)) <= 86400"
           )

    create constraint(
             :delivery_support_elevations,
             :delivery_support_elevations_revocation_pairing,
             check: "(revoked_at IS NULL) = (revoked_by_account_id IS NULL)"
           )
  end
end
