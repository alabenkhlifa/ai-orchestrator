defmodule SddOrchestrator.Repo.Migrations.CreatePreviewDeployments do
  use Ecto.Migration

  def change do
    create table(:preview_deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false

      # A preview deployment is *of* one attempt's verified commit, unlike
      # evidence, which outlives the attempt that produced it. Losing the
      # attempt would leave a deployment nobody can place, so the link is
      # required and cascades rather than being cleared.
      add :attempt_id, references(:run_attempts, type: :binary_id, on_delete: :delete_all),
        null: false

      # The exact thing deployed. A different commit is a different deployment,
      # never a new state of this one.
      add :branch, :string, null: false
      add :commit_sha, :string, null: false

      # The project's preconfigured, authorized preview path and the provider
      # that serves it. Neither is chosen by a run or by a worker.
      add :path, :string, null: false
      add :provider, :string, null: false

      # Everything kept about the provider: an opaque handle, and one
      # participant-safe link. No credential, no signed query string, and
      # nothing that could be replayed to authenticate.
      add :provider_ref, :string
      add :link, :string

      add :status, :string, null: false, default: "pending"
      add :failure_reason, :string

      add :requested_at, :utc_datetime_usec, null: false
      add :ready_at, :utc_datetime_usec

      # The deadline the configured adapter policy set for this request, and the
      # provider's own expiry for the deployment. They stop the preview for
      # different reasons and are recorded separately.
      add :timeout_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec

      # The cleanup seam later project deletion and cancellation call. The
      # command identifier is durable before the provider is asked, so a cleanup
      # interrupted by a restart stays visible as owed.
      add :cleanup_state, :string, null: false, default: "none"
      add :cleanup_command_id, :string

      add :superseded_by_id,
          references(:preview_deployments, type: :binary_id, on_delete: :nilify_all)

      add :state_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:preview_deployments, [:project_id])
    create index(:preview_deployments, [:feature_id])
    create index(:preview_deployments, [:run_id])
    create index(:preview_deployments, [:superseded_by_id])

    # Idempotency as a property of the store rather than of callers: requesting
    # the same run, attempt, and commit twice cannot produce a second
    # deployment, whichever process asks.
    create unique_index(:preview_deployments, [:run_id, :attempt_id, :commit_sha],
             name: :preview_deployments_binding_index
           )

    create constraint(:preview_deployments, :preview_deployments_status_allowed,
             check:
               "status IN ('pending', 'ready', 'failed', 'timed_out', 'expired', 'superseded')"
           )

    create constraint(:preview_deployments, :preview_deployments_cleanup_state_allowed,
             check: "cleanup_state IN ('none', 'requested', 'done', 'failed')"
           )

    create constraint(:preview_deployments, :preview_deployments_branch_length,
             check: "octet_length(branch) > 0 AND octet_length(branch) <= 200"
           )

    create constraint(:preview_deployments, :preview_deployments_commit_sha_length,
             check: "octet_length(commit_sha) > 0 AND octet_length(commit_sha) <= 64"
           )

    create constraint(:preview_deployments, :preview_deployments_path_shape,
             check: "path ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'"
           )

    create constraint(:preview_deployments, :preview_deployments_provider_length,
             check: "octet_length(provider) > 0 AND octet_length(provider) <= 100"
           )

    # A provider reference addresses a deployment at the provider. It carries no
    # query, no fragment, and nothing that looks like a scheme, so it cannot
    # quietly become a link a reader tries to follow.
    create constraint(:preview_deployments, :preview_deployments_provider_ref_shape,
             check: """
             provider_ref IS NULL
               OR (provider_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/=-]{0,199}$'
                   AND provider_ref NOT LIKE '%//%')
             """
           )

    # The database-level form of "a preview link is safe to hand a participant".
    # User info, a query string, and a fragment are all excluded by construction,
    # because a token in a query string is the usual way a preview URL turns into
    # a credential. Plain `http` is allowed only on the loopback host a local
    # worker serves, where the link never leaves the participant's own machine.
    create constraint(:preview_deployments, :preview_deployments_link_safe,
             check: """
             link IS NULL
               OR link ~ '^https://[A-Za-z0-9._~-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
               OR link ~ '^http://(localhost|127[.]0[.]0[.]1)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
             """
           )

    # A machine-readable token, never provider prose: prose is where a leaked
    # credential would ride into a stored record.
    create constraint(:preview_deployments, :preview_deployments_failure_reason_shape,
             check: "failure_reason IS NULL OR failure_reason ~ '^[a-z][a-z0-9_]{0,99}$'"
           )

    create constraint(:preview_deployments, :preview_deployments_ready_link,
             check: "status <> 'ready' OR link IS NOT NULL"
           )

    create constraint(:preview_deployments, :preview_deployments_failure_reason_present,
             check: "status NOT IN ('failed', 'timed_out') OR failure_reason IS NOT NULL"
           )

    create constraint(:preview_deployments, :preview_deployments_supersession_pairing,
             check: "(status = 'superseded') = (superseded_by_id IS NOT NULL)"
           )

    create constraint(:preview_deployments, :preview_deployments_supersession_distinct,
             check: "superseded_by_id IS NULL OR superseded_by_id <> id"
           )

    create constraint(:preview_deployments, :preview_deployments_cleanup_pairing,
             check: "(cleanup_state = 'none') = (cleanup_command_id IS NULL)"
           )

    create constraint(:preview_deployments, :preview_deployments_state_version_positive,
             check: "state_version > 0"
           )

    # The binding is what gives a deployment its identity, so it is frozen here
    # rather than by convention. Repointing a row at another commit, attempt,
    # run, branch, or path would silently turn one deployment into a claim about
    # something it never deployed.
    execute """
            CREATE OR REPLACE FUNCTION preview_deployments_freeze_binding()
            RETURNS trigger AS $$
            BEGIN
              IF NEW.id IS DISTINCT FROM OLD.id
                OR NEW.project_id IS DISTINCT FROM OLD.project_id
                OR NEW.feature_id IS DISTINCT FROM OLD.feature_id
                OR NEW.run_id IS DISTINCT FROM OLD.run_id
                OR NEW.attempt_id IS DISTINCT FROM OLD.attempt_id
                OR NEW.branch IS DISTINCT FROM OLD.branch
                OR NEW.commit_sha IS DISTINCT FROM OLD.commit_sha
                OR NEW.path IS DISTINCT FROM OLD.path
                OR NEW.provider IS DISTINCT FROM OLD.provider
                OR NEW.requested_at IS DISTINCT FROM OLD.requested_at
                OR NEW.timeout_at IS DISTINCT FROM OLD.timeout_at
                OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at
              THEN
                RAISE EXCEPTION 'a preview deployment binding is recorded once';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS preview_deployments_freeze_binding();"

    execute """
            CREATE TRIGGER preview_deployments_binding_frozen
            BEFORE UPDATE ON preview_deployments
            FOR EACH ROW EXECUTE FUNCTION preview_deployments_freeze_binding();
            """,
            "DROP TRIGGER IF EXISTS preview_deployments_binding_frozen ON preview_deployments;"
  end
end
