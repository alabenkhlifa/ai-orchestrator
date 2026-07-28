defmodule SddOrchestrator.Repo.Migrations.AddOnboardingAttemptOrigin do
  use Ecto.Migration

  # The onboarding attempt becomes the one shared, resumable workflow record for
  # both repository sources. A hosted-origin attempt (GitHub onboarding, signed
  # in) owns a hosted workspace exactly as before. A device-origin attempt
  # (accountless local onboarding) references only an opaque device-workspace id,
  # carries no hosted owning workspace, and gains hosted availability only after a
  # verified hosted sign-in records the proven hosted prerequisite. A browser-flow
  # binding secures the prerequisite handoff and return.

  def up do
    alter table(:project_onboarding_attempts) do
      add :origin_kind, :string, null: false, default: "hosted"
      # Opaque device-workspace id for device-origin attempts. No foreign key: a
      # device workspace lives only in device persistence and is intentionally
      # absent from the hosted database.
      add :device_workspace_id, :binary_id
      # The hosted workspace proven by a verified sign-in during a device-origin
      # attempt. It makes hosted storage available and becomes the hosted target
      # if the user then chooses hosted; it never confers hosted ownership of the
      # attempt itself, so hosted-scoped ownership queries ignore it.
      add :hosted_prerequisite_workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all)

      # Digest binding the attempt to the current signed browser session so a
      # prerequisite return cannot be replayed against another browser flow.
      add :browser_flow_binding, :string
    end

    # Device-origin attempts have no hosted owning workspace until (optionally)
    # they choose hosted at the very end, so the owning workspace must be nullable.
    execute("ALTER TABLE project_onboarding_attempts ALTER COLUMN workspace_id DROP NOT NULL")

    create index(:project_onboarding_attempts, [:device_workspace_id])
    create index(:project_onboarding_attempts, [:hosted_prerequisite_workspace_id])

    create constraint(:project_onboarding_attempts, :onboarding_attempt_origin_kind,
             check: "origin_kind IN ('hosted','device')"
           )

    # Each origin has exactly one owning shape: a hosted-origin attempt owns a
    # hosted workspace and references no device workspace; a device-origin attempt
    # references a device workspace and never carries a hosted owning workspace.
    create constraint(:project_onboarding_attempts, :onboarding_attempt_origin_shape,
             check:
               "(origin_kind = 'hosted' AND workspace_id IS NOT NULL AND device_workspace_id IS NULL AND hosted_prerequisite_workspace_id IS NULL) OR (origin_kind = 'device' AND workspace_id IS NULL AND device_workspace_id IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:project_onboarding_attempts, :onboarding_attempt_origin_shape)
    drop constraint(:project_onboarding_attempts, :onboarding_attempt_origin_kind)
    drop index(:project_onboarding_attempts, [:hosted_prerequisite_workspace_id])
    drop index(:project_onboarding_attempts, [:device_workspace_id])

    # Restore the not-null owning workspace. Device-origin attempts, which have a
    # null workspace_id, are transient and are removed so the constraint can be
    # reinstated cleanly on rollback.
    execute("DELETE FROM project_onboarding_attempts WHERE workspace_id IS NULL")
    execute("ALTER TABLE project_onboarding_attempts ALTER COLUMN workspace_id SET NOT NULL")

    alter table(:project_onboarding_attempts) do
      remove :browser_flow_binding
      remove :hosted_prerequisite_workspace_id
      remove :device_workspace_id
      remove :origin_kind
    end
  end
end
