#!/usr/bin/env bash
# Drop leftover per-partition test and browser-suite databases from the local
# Postgres container. Every `run_proof.py` worktree partition and every e2e run
# creates its own database and nothing removes them. Dry run by default.
#
#   .agents/scripts/drop_test_databases.sh              # list what would be dropped
#   .agents/scripts/drop_test_databases.sh --yes        # drop them
#   .agents/scripts/drop_test_databases.sh --e2e --yes  # drop the browser ones too
#
# The two browser-suite databases are kept by default, because the suite reuses
# them the way development reuses its own. They are worth dropping when one has
# gone stale: the suite migrates them in place, so a database left behind by an
# older branch can hold a half-applied migration and fail a scenario with a
# duplicate column, which reads as a product defect and is not one.
set -euo pipefail

container="${SDD_POSTGRES_CONTAINER:-sdd_orchestrator_postgres}"
include_e2e=false
confirmed=false

for argument in "$@"; do
  case "$argument" in
    --e2e) include_e2e=true ;;
    --yes) confirmed=true ;;
    *)
      echo "unknown option: $argument" >&2
      echo "usage: drop_test_databases.sh [--e2e] [--yes]" >&2
      exit 2
      ;;
  esac
done

keep_regex='^(sdd_orchestrator_dev|sdd_orchestrator_test)$'

if [[ "$include_e2e" == false ]]; then
  keep_regex='^(sdd_orchestrator_dev|sdd_orchestrator_test|sdd_orchestrator_e2e_desktop|sdd_orchestrator_e2e_mobile)$'
fi

psql() {
  docker exec "$container" psql -U postgres -Atc "$1"
}

mapfile -t candidates < <(psql "select datname from pg_database where datname like 'sdd_orchestrator_test%' or datname like 'sdd_orchestrator_e2e_%' order by datname;")

targets=()
for db in "${candidates[@]}"; do
  [[ "$db" =~ $keep_regex ]] && continue
  targets+=("$db")
done

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "Nothing to drop."
  exit 0
fi

printf '%s\n' "${targets[@]}"
echo "${#targets[@]} database(s)."

if [[ "$confirmed" == false ]]; then
  echo "Dry run. Re-run with --yes to drop them."
  exit 0
fi

for db in "${targets[@]}"; do
  psql "drop database if exists \"$db\" with (force);" >/dev/null
  echo "dropped $db"
done
