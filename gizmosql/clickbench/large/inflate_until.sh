#!/usr/bin/env bash
# Inflate the hits table to TARGET rows by appending copies of its own rows in
# bounded chunks (INSERT INTO hits SELECT * FROM hits WHERE rowid < add) until it
# reaches TARGET. Prints per-step elapsed time and rows/sec.
#
# Why bounded chunks, not doubling the whole table at once: a single giant
# `INSERT INTO hits SELECT * FROM hits` at multi-billion-row scale buffers the new
# data up to DuckDB's memory_limit (~80% of RAM) and then flushes single-threaded
# — one core pegged for a very long time. Capping each insert at CHUNK_ROWS keeps
# every transaction small enough to stay fully parallel and checkpoint quickly
# (same total rows written, just not in one transaction). rowid is used (not
# LIMIT, a single-threaded streaming operator in DuckDB) so the scan parallelizes;
# the table is append-only so rowids are contiguous 0..current-1 and, with
# add <= current, `rowid < add` adds exactly `add` rows.
#
# Assumes a server is already running and hits already holds the base data.
#
# Usage:  ./inflate_until.sh [TARGET_ROWS]    (default: env TARGET_ROWS or 1e9)
# Env:    CHUNK_ROWS  max rows per insert (default 250000000)
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
CHUNK="${CHUNK_ROWS:-250000000}"   # max rows per insert (bounded transaction)
(( CHUNK > 0 )) || { echo "ERROR: CHUNK_ROWS must be > 0" >&2; exit 1; }

# Format a duration (seconds) as 45s / 3m12s / 1h04m.
fmt_dur() {
  local s=$1
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else                      printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}
START_TS=$(date +%s)

# Append in bounded chunks until TARGET. add = min(CHUNK, remaining, current):
#   - capping at `current` keeps `rowid < add` exact,
#   - capping at CHUNK keeps each transaction parallel and off the memory_limit,
#   - capping at the remainder lands exactly on TARGET.
# (Arithmetic uses ?: ternaries, not `(( )) && ...`, so it is set -e safe.)
while (( current < TARGET )); do
  add=$(( TARGET - current ))
  add=$(( add > CHUNK ? CHUNK : add ))
  add=$(( add > current ? current : add ))
  echo "Append: +${add} -> $((current + add))  (target ${TARGET})" >&2
  prev=$current; t0=$(date +%s)
  gizmosql_client --quiet --bail --command "${SET_PAR} INSERT INTO hits SELECT * FROM hits WHERE rowid < ${add};"
  current="$(hits_rows)"
  dt=$(( $(date +%s) - t0 )); dt=$(( dt < 1 ? 1 : dt ))
  echo "  +$((current - prev)) rows in $(fmt_dur "$dt") ($(( (current - prev) / dt )) rows/s) -> ${current}" >&2
done

echo "Final rows: ${current}  (inflated in $(fmt_dur $(( $(date +%s) - START_TS ))))" >&2
