defmodule SddOrchestrator.Repo.Migrations.BackfillOwnerDisplayProfiles do
  use Ecto.Migration

  # Hosted projects registered before the owner's display profile was created
  # with the project have no owner label at all. This backfill gives each of
  # them exactly one, under the same rule registration now applies: the owner's
  # GitHub login, never their email, and never an automatic suffix.
  #
  # It is a data migration, so it is written as explicit `up/0` and `down/0`
  # rather than a reversible `change/0`.

  # Must match `SddOrchestrator.Participation.default_owner_display_name/0`.
  # Used when the owner has no GitHub identity, so no personal data is invented
  # for a label every project member reads.
  @fallback_label "Project owner"

  # A GitHub login is ASCII letters, digits, and hyphens, at most 39
  # characters. Restricting the derived label to that shape keeps the SQL
  # comparison key (`lower/1`) exactly equivalent to the application's key
  # derivation (NFKC then default case folding), which is identity for ASCII.
  # Anything else — including the impossible email-shaped case — takes the
  # neutral fallback instead of writing a key the application would compute
  # differently.
  @login_shape "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"

  def up do
    # Every guard below is a `NOT EXISTS`, so re-running this migration inserts
    # nothing a second time and overwrites no label anyone has since chosen. It
    # touches only `project_member_profiles`: project ownership lives in the
    # workspace and participation in `project_participants`, and neither is
    # read for anything but resolving the owner account, nor written at all.
    execute("""
    INSERT INTO project_member_profiles (
      id,
      project_id,
      account_id,
      role,
      state,
      display_name,
      display_name_key,
      inserted_at,
      updated_at
    )
    SELECT
      gen_random_uuid(),
      project.id,
      workspace.account_id,
      'owner',
      'active',
      label.display_name,
      lower(label.display_name),
      date_trunc('second', now() AT TIME ZONE 'utc'),
      date_trunc('second', now() AT TIME ZONE 'utc')
    FROM projects AS project
    JOIN personal_workspaces AS workspace ON workspace.id = project.workspace_id
    LEFT JOIN github_identities AS identity ON identity.account_id = workspace.account_id
    CROSS JOIN LATERAL (
      SELECT
        CASE
          WHEN identity.login ~ '#{@login_shape}' THEN identity.login
          ELSE '#{@fallback_label}'
        END AS display_name
    ) AS label
    WHERE project.storage_mode = 'hosted'
      AND project.lifecycle_state = 'active'
      AND NOT EXISTS (
        SELECT 1
        FROM project_member_profiles AS existing
        WHERE existing.project_id = project.id
          AND existing.account_id = workspace.account_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM project_member_profiles AS taken
        WHERE taken.project_id = project.id
          AND taken.state = 'active'
          AND taken.display_name_key = lower(label.display_name)
      )
    """)
  end

  def down do
    # Deliberately a no-op. Once backfilled, an owner label is indistinguishable
    # from one the owner typed themselves, so deleting rows here would destroy
    # chosen names to undo a derived default. Nothing depends on the rows being
    # absent either: owner authorization no longer reads the profile, so rolling
    # this migration back leaves a correct, working state.
    :ok
  end
end
