defmodule SddOrchestrator.Repo.Migrations.CreateHostedLocalRepositoryBindings do
  use Ecto.Migration

  def up do
    create table(:hosted_local_repository_bindings, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :worker_id, references(:local_workers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :last_validated_at, :utc_datetime, null: false
    end

    create index(:hosted_local_repository_bindings, [:worker_id])

    execute("""
    CREATE FUNCTION purge_hosted_local_bindings_on_worker_revocation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.state = 'revoked' AND OLD.state IS DISTINCT FROM NEW.state THEN
        DELETE FROM hosted_local_repository_bindings
        WHERE worker_id = NEW.id;
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER purge_hosted_local_bindings_on_worker_revocation
    AFTER UPDATE OF state ON local_workers
    FOR EACH ROW
    EXECUTE FUNCTION purge_hosted_local_bindings_on_worker_revocation()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER purge_hosted_local_bindings_on_worker_revocation
    ON local_workers
    """)

    execute("DROP FUNCTION purge_hosted_local_bindings_on_worker_revocation()")

    drop table(:hosted_local_repository_bindings)
  end
end
