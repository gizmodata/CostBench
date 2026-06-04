#!/usr/bin/env bash
# Inflate the hits table to TARGET rows by repeatedly doubling it
# (INSERT INTO hits SELECT * FROM hits), then a final LIMIT top-off to land
# exactly on TARGET. Mirrors CostBench's clickhouse-cloud/inflate_until.sh,
# translated to DuckDB / GizmoSQL.
#
# DuckDB MVCC means the SELECT sees the pre-insert snapshot, so each statement
# cleanly doubles the table (it does not read its own freshly-inserted rows).
#
# Assumes a server is already running and hits already holds the base data.
#
# Usage: ./inflate_until.sh [TARGET_ROWS]   (default: env TARGET_ROWS or 1e9)
set -euo pipefail
cd "$(dirname "$0")"
. ./util.sh

TARGET="${1:-${TARGET_ROWS:-1000000000}}"

current="$(hits_rows)"
echo "Start rows: ${current}  target: ${TARGET}" >&2
[[ "$current" =~ ^[0-9]+$ ]] || { echo "ERROR: could not read row count ('$current')" >&2; exit 1; }
(( current > 0 ))             || { echo "ERROR: hits is empty; load the base data first" >&2; exit 1; }

# Degenerate case: the base load already meets/exceeds the target (we cannot
# shrink the table), so there is nothing to inflate.
if (( current >= TARGET )); then
  echo "Base rows (${current}) already >= target (${TARGET}); nothing to inflate." >&2
  exit 0
fi

# Doubling phase: stop before we would overshoot TARGET.
while (( current * 2 <= TARGET )); do
  echo "Doubling: ${current} -> $((current * 2))  (target ${TARGET})" >&2
  gizmosql_client --quiet --bail --command "INSERT INTO hits SELECT * FROM hits;"
  current="$(hits_rows)"
done

# Final top-off to land exactly on TARGET.
if (( current < TARGET )); then
  remaining=$(( TARGET - current ))
  echo "Top-off: +${remaining} -> ${TARGET}" >&2
  gizmosql_client --quiet --bail --command "INSERT INTO hits SELECT * FROM hits LIMIT ${remaining};"
  current="$(hits_rows)"
fi

echo "Final rows: ${current}" >&2
