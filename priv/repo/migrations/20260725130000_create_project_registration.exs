defmodule SddOrchestrator.Repo.Migrations.CreateProjectRegistration do
  use Ecto.Migration

  def change do
    # Additive extension of the Task 4 base `projects` read-model with the
    # registration attributes this task owns. Existing catalog rows keep their
    # identity and display name; these columns are populated by the registration
    # transaction (and derived name key by the shared changeset).
    alter table(:projects) do
      # NFKC + Unicode default case-folded comparison key. Nullable so the
      # additive column never invalidates an existing row; every registered
      # project sets it and the unique index below enforces workspace uniqueness.
      add :name_key, :string
      add :storage_mode, :string
      add :lifecycle_state, :string, null: false, default: "active"

      # Records which onboarding attempt produced the project so a retry of an
      # already-committed attempt is idempotent. Nilified if the attempt is later
      # pruned; the project is never deleted with it.
      add :onboarding_attempt_id,
          references(:project_onboarding_attempts, type: :binary_id, on_delete: :nilify_all)
    end

    # Case-insensitive project-name uniqueness within one personal workspace.
    create unique_index(:projects, [:workspace_id, :name_key])
    create index(:projects, [:onboarding_attempt_id])

    # One canonical repository connection per project. Repository identity is the
    # provider's stable numeric id; owner/name/url/visibility are mutable display
    # and access metadata refreshed on validated reads (Task 8).
    create table(:repository_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workspace_id,
          references(:personal_workspaces, type: :binary_id, on_delete: :delete_all), null: false

      add :provider, :string, null: false, default: "github"
      add :provider_repository_id, :bigint, null: false
      add :owner, :string
      add :name, :string
      add :full_name, :string
      add :html_url, :string
      add :visibility, :string
      add :private, :boolean
      add :organization, :string
      add :installation_id, :bigint
      add :last_validated_at, :utc_datetime
      add :state, :string, null: false, default: "connected"

      timestamps(type: :utc_datetime)
    end

    # One project per repository within a workspace, and one connection per project.
    create unique_index(
             :repository_connections,
             [:workspace_id, :provider, :provider_repository_id],
             name: :repository_connections_workspace_provider_repo_index
           )

    create unique_index(:repository_connections, [:project_id])

    # Hosted project-data storage root, initialized in the same transaction as its
    # project. The device storage adapter and its production preparation are owned
    # by specs/02-local-project-onboarding/; this slice implements only hosted.
    create table(:hosted_project_storages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :root, :string, null: false
      add :state, :string, null: false, default: "ready"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hosted_project_storages, [:project_id])
  end
end
