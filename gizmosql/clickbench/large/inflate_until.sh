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

# preserve_insertion_order=false lets DuckDB run the INSERT...SELECT fully in
# parallel (row order in the inflated table is irrelevant to the benchmark).
SET_PAR="SET preserve_insertion_order=false;"

# Doubling phase: stop before we would overshoot TARGET.
while (( current * 2 <= TARGET )); do
  echo "Doubling: ${current} -> $((current * 2))  (target ${TARGET})" >&2
  gizmosql_client --quiet --bail --command "${SET_PAR} INSERT INTO hits SELECT * FROM hits;"
  current="$(hits_rows)"
done

# Final top-off to land exactly on TARGET. Use a parallel `rowid < N` predicate
# rather than `LIMIT N`: LIMIT is a single-threaded streaming operator in DuckDB
# (one core, very slow at this scale), whereas a rowid filter parallelizes the
# scan + insert across all cores. The table is append-only (we never delete), so
# rowids are contiguous 0..current-1, and remaining < current after the doubling
# loop — so `rowid < remaining` selects exactly `remaining` rows.
if (( current < TARGET )); then
  remaining=$(( TARGET - current ))
  echo "Top-off: +${remaining} -> ${TARGET}" >&2
  gizmosql_client --quiet --bail --command "${SET_PAR} INSERT INTO hits SELECT * FROM hits WHERE rowid < ${remaining};"
  current="$(hits_rows)"
fi

echo "Final rows: ${current}" >&2
