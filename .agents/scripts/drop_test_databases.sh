#!/usr/bin/env bash
# Drop leftover per-partition test and browser-suite databases from the local
# Postgres container. Every `run_proof.py` worktree partition and every e2e run
# creates its own database and nothing removes them. Dry run by default.
#
#   .agents/scripts/drop_test_databases.sh          # list what would be dropped
#   .agents/scripts/drop_test_databases.sh --yes    # drop them
set -euo pipefail

container="${SDD_POSTGRES_CONTAINER:-sdd_orchestrator_postgres}"
keep_regex='^(sdd_orchestrator_dev|sdd_orchestrator_test|sdd_orchestrator_e2e_desktop|sdd_orchestrator_e2e_mobile)$'

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

if [[ "${1:-}" != "--yes" ]]; then
  echo "Dry run. Re-run with --yes to drop them."
  exit 0
fi

for db in "${targets[@]}"; do
  psql "drop database if exists \"$db\" with (force);" >/dev/null
  echo "dropped $db"
done
