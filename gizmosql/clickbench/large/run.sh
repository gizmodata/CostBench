#!/usr/bin/env bash
# Run the 43 ClickBench queries 3x each (best of three) against GizmoSQL and emit
# a CostBench-format raw result JSON to stdout.
#
# For fair cold-vs-hot behaviour the server is restarted and the OS page cache is
# dropped before EACH query (matching the existing ClickBench gizmosql harness),
# so the three timings per query are: first run (cold-ish) then two warm runs.
#
# Metadata comes from the environment (benchmark.sh sets these):
#   SYSTEM MACHINE MEMORY_GIB CLUSTER_SIZE DATA_SIZE LOAD_TIME COMMENT DATE
#   TRIES (default 3)   DROP_CACHES (1 to drop Linux caches; no-op elsewhere)
set -uo pipefail
cd "$(dirname "$0")"
. ./util.sh
export QUIET_SERVER=1   # the per-query restarts are routine; we print our own progress

SYSTEM="${SYSTEM:-GizmoSQL}"
MACHINE="${MACHINE:-unknown}"
MEMORY_GIB="${MEMORY_GIB:-0}"
CLUSTER_SIZE="${CLUSTER_SIZE:-1}"
DATA_SIZE="${DATA_SIZE:-0}"
DURABLE_SIZE="${DURABLE_SIZE:-0}"
LOAD_TIME="${LOAD_TIME:-0}"
COMMENT="${COMMENT:-}"
TRIES="${TRIES:-3}"
DROP_CACHES="${DROP_CACHES:-1}"

# --- Server/engine version (best effort) ---
start_gizmosql
VERSION="$(gizmosql_scalar "SELECT gizmosql_version();")"
[ -z "$VERSION" ] && VERSION="$(gizmosql_scalar "SELECT version();")"
[ -z "$VERSION" ] && VERSION="unknown"
stop_gizmosql

# --- Read the queries (one per line; portable, no mapfile) ---
QUERIES=()
while IFS= read -r line || [ -n "$line" ]; do
  QUERIES+=("$line")
done < queries.sql

drop_caches() {
  [ "$DROP_CACHES" = "1" ] || return 0
  sync 2>/dev/null || true
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
}

# Emit the comma-separated "[t1, t2, t3]," rows for every query, with clear
# per-query progress on stderr so the per-query server restarts read as forward
# progress, not an endless loop.
emit_rows() {
  local first=1 query tmp out qnum=0 total=0 q
  for q in "${QUERIES[@]}"; do [ -n "${q// }" ] && total=$((total + 1)); done
  printf '[%s] running %d queries x%d tries (server restart + cache drop per query)...\n' \
    "$(date -u +%H:%M:%S)" "$total" "$TRIES" >&2

  for query in "${QUERIES[@]}"; do
    [ -z "${query// }" ] && continue
    qnum=$((qnum + 1))

    drop_caches
    start_gizmosql

    tmp="$(mktemp)"
    {
      printf '%s\n' ".timer on"
      printf '%s\n' ".mode trash"
      for _ in $(seq 1 "$TRIES"); do printf '%s\n' "$query"; done
    } > "$tmp"
    out="$(gizmosql_client --quiet --file "$tmp" 2>&1)"
    rm -f "$tmp"

    stop_gizmosql

    # Pull the per-run "Run Time: <secs>s" values the .timer prints.
    times=()
    while IFS= read -r t; do times+=("$t"); done < <(
      printf '%s\n' "$out" | grep -oE 'Run Time: [0-9.]+s' | grep -oE '[0-9.]+'
    )

    # Warn (don't fail) when a query produced no timing at all.
    [ "${#times[@]}" -eq 0 ] && echo "  WARN: query ${qnum} produced no 'Run Time' output" >&2

    # Build exactly TRIES values, filling missing/failed runs with null.
    local arr=() i
    for (( i=0; i<TRIES; i++ )); do arr+=("${times[$i]:-null}"); done
    local joined; joined="$(printf '%s, ' "${arr[@]}")"; joined="${joined%, }"

    printf '[%s] query %d/%d  ->  %ss\n' "$(date -u +%H:%M:%S)" "$qnum" "$total" "$joined" >&2

    [ "$first" -eq 0 ] && printf ',\n'
    printf '        [%s]' "$joined"
    first=0
  done
  printf '\n'
}

ROWS="$(emit_rows)"
DATE_ISO="${DATE:-$(date -u +%F)}"
VERSION="${VERSION//\"/}"

# Sanitize the free-text COMMENT so it can never corrupt the JSON it sits in.
COMMENT="${COMMENT//\\/}"
COMMENT="${COMMENT//\"/}"
COMMENT="${COMMENT//$'\n'/ }"
COMMENT="${COMMENT//$'\r'/ }"

# Guard against a fully-failed run silently producing an all-null result.
if ! printf '%s' "$ROWS" | grep -qE '[0-9]'; then
  echo "WARNING: every query timing is null — the result is unusable. Verify gizmosql_client" >&2
  echo "         supports '.timer on' / '.mode trash' and prints 'Run Time: <n>s'." >&2
fi

cat <<JSON
{
    "system": "${SYSTEM}",
    "version": "${VERSION}",
    "date": "${DATE_ISO}",
    "machine": "${MACHINE}",
    "cluster_size": ${CLUSTER_SIZE},
    "memory_size": ${MEMORY_GIB},
    "proprietary": "no",
    "tuned": "no",
    "comment": "${COMMENT}",
    "tags": ["C++", "column-oriented", "DuckDB", "Arrow Flight SQL", "single-node"],
    "load_time": ${LOAD_TIME},
    "data_size": ${DATA_SIZE},
    "durable_size": ${DURABLE_SIZE},
    "result": [
${ROWS}    ]
}
JSON
