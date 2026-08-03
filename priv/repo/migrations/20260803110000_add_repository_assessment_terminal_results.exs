defmodule SddOrchestrator.Repo.Migrations.AddRepositoryAssessmentTerminalResults do
  use Ecto.Migration

  @default_limits_json ~s({"max_paths":2000,"max_files":64,"max_total_bytes":524288,"max_file_bytes":65536,"timeout_ms":10000})

  def up do
    alter table(:repository_assessments) do
      add :scan_protocol_version, :integer
      add :scan_limits, :map
      add :findings, {:array, :map}
      add :structure, {:array, :map}
      add :stats, :map
      add :failure_code, :string
      add :terminal_at, :utc_datetime_usec
    end

    execute("""
    UPDATE repository_assessments
    SET scan_protocol_version = 1,
        scan_limits = '#{@default_limits_json}'::jsonb
    WHERE scan_protocol_version IS NULL OR scan_limits IS NULL
    """)

    alter table(:repository_assessments) do
      modify :scan_protocol_version, :integer, null: false
      modify :scan_limits, :map, null: false
    end

    drop constraint(:repository_assessments, :repository_assessments_pending_state)

    create constraint(:repository_assessments, :repository_assessments_state,
             check: "state IN ('pending_scan', 'completed', 'canceled', 'failed')"
           )

    create constraint(:repository_assessments, :repository_assessments_scan_contract,
             check:
               "scan_protocol_version > 0 AND jsonb_typeof(scan_limits) = 'object' AND scan_limits ?& ARRAY['max_paths', 'max_files', 'max_total_bytes', 'max_file_bytes', 'timeout_ms'] AND (scan_limits - ARRAY['max_paths', 'max_files', 'max_total_bytes', 'max_file_bytes', 'timeout_ms']::text[]) = '{}'::jsonb"
           )

    create constraint(:repository_assessments, :repository_assessments_terminal_shape,
             check: """
             (state = 'pending_scan'
               AND findings IS NULL AND structure IS NULL AND stats IS NULL
               AND failure_code IS NULL AND terminal_at IS NULL)
             OR
             (state = 'completed'
               AND findings IS NOT NULL AND structure IS NOT NULL AND stats IS NOT NULL
               AND failure_code IS NULL AND terminal_at IS NOT NULL)
             OR
             (state = 'canceled'
               AND findings = ARRAY[]::jsonb[] AND structure = ARRAY[]::jsonb[]
               AND stats = '{}'::jsonb AND failure_code IS NULL AND terminal_at IS NOT NULL)
             OR
             (state = 'failed'
               AND findings = ARRAY[]::jsonb[] AND structure = ARRAY[]::jsonb[]
               AND stats = '{}'::jsonb AND failure_code IS NOT NULL AND terminal_at IS NOT NULL)
             """
           )

    create constraint(:repository_assessments, :repository_assessments_failure_code,
             check: """
             failure_code IS NULL OR failure_code IN (
               'file_limit_exceeded', 'file_size_limit_exceeded', 'invalid_command',
               'path_limit_exceeded', 'repository_unavailable', 'root_escape',
               'stale_commit', 'time_limit_exceeded', 'total_byte_limit_exceeded'
             )
             """
           )
  end

  def down do
    drop constraint(:repository_assessments, :repository_assessments_failure_code)
    drop constraint(:repository_assessments, :repository_assessments_terminal_shape)
    drop constraint(:repository_assessments, :repository_assessments_scan_contract)
    drop constraint(:repository_assessments, :repository_assessments_state)

    execute("DELETE FROM repository_assessments WHERE state <> 'pending_scan'")

    alter table(:repository_assessments) do
      remove :terminal_at
      remove :failure_code
      remove :stats
      remove :structure
      remove :findings
      remove :scan_limits
      remove :scan_protocol_version
    end

    create constraint(:repository_assessments, :repository_assessments_pending_state,
             check: "state = 'pending_scan'"
           )
  end
end
