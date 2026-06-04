#!/usr/bin/env bash
# End-to-end GizmoSQL CostBench run at a single scale on a single machine.
#
# Required env:
#   MACHINE       instance label, e.g. c6a.4xlarge / r8gd.metal-48xl
#   MEMORY_GIB    instance RAM in GiB (must match the pricing file's memory_size)
#   SCALE         1B | 10B | 100B   (output dir + db filename)
#   TARGET_ROWS   row target, e.g. 1000000000
#
# Optional env:
#   INSTALL=1     apt deps + install GizmoSQL via the one-line installer first
#   HITS_PARQUET / HITS_URL   base data source (see load_once_from_url.sh)
#   DROP_CACHES=1 drop the Linux page cache before each query (default on)
#   STORAGE_DESC  free-text note for the result comment (e.g. "local NVMe")
#
# Produces: results_<SCALE>/<MACHINE>.json   (raw per-query runtimes)
set -euo pipefail
cd "$(dirname "$0")"

MACHINE="${MACHINE:?set MACHINE (e.g. c6a.4xlarge)}"
MEMORY_GIB="${MEMORY_GIB:?set MEMORY_GIB (instance RAM in GiB)}"
SCALE="${SCALE:?set SCALE (1B|10B|100B)}"
TARGET_ROWS="${TARGET_ROWS:?set TARGET_ROWS (e.g. 1000000000)}"

export DB_FILE="${DB_FILE:-clickbench_${SCALE}.db}"
. ./util.sh

if [ "${INSTALL:-0}" = "1" ]; then
  echo "== Installing dependencies + GizmoSQL ==" >&2
  sudo apt-get update -y
  sudo apt-get install -y curl unzip wget jq netcat-openbsd
  curl -fsSL https://install.gizmosql.com/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

OUT_DIR="results_${SCALE}"
mkdir -p "$OUT_DIR"

echo "== Load base + inflate to ${TARGET_ROWS} rows (${SCALE}) on ${MACHINE} ==" >&2
start_gizmosql
LOAD_START="$(date +%s)"
./load_once_from_url.sh
BASE_ROWS="$(hits_rows)"
./inflate_until.sh "$TARGET_ROWS"
gizmosql_client --quiet --bail --command "CHECKPOINT;" >/dev/null 2>&1
LOAD_END="$(date +%s)"
LOAD_TIME=$(( LOAD_END - LOAD_START ))
ROWS="$(hits_rows)"
stop_gizmosql

# DuckDB database file size on disk (bytes): the query-ready footprint that
# lives on the instance's included local NVMe (not billed separately).
DATA_SIZE="$(wc -c < "$DB_FILE" | tr -d '[:space:]')"

# Durable storage footprint: a copy of the source data kept in S3, sized as the
# source parquet scaled to the final row count. This is what storage is billed
# on under the "NVMe runtime + S3 durable" model.
HITS_PARQUET="${HITS_PARQUET:-hits.parquet}"
PARQUET_BYTES=0
[ -f "$HITS_PARQUET" ] && PARQUET_BYTES="$(wc -c < "$HITS_PARQUET" | tr -d '[:space:]')"
DURABLE_SIZE="$(awk -v p="$PARQUET_BYTES" -v b="$BASE_ROWS" -v f="$ROWS" \
  'BEGIN { if (b > 0) printf "%.0f", p * (f / b); else print 0 }')"
echo "rows=${ROWS} load_time=${LOAD_TIME}s data_size=${DATA_SIZE} durable_size=${DURABLE_SIZE} bytes" >&2

echo "== Run 43 queries (best of 3) ==" >&2
SYSTEM="GizmoSQL" \
MACHINE="$MACHINE" \
MEMORY_GIB="$MEMORY_GIB" \
CLUSTER_SIZE=1 \
DATA_SIZE="$DATA_SIZE" \
DURABLE_SIZE="$DURABLE_SIZE" \
LOAD_TIME="$LOAD_TIME" \
COMMENT="${SCALE} rows (${ROWS}); single node; DuckDB out-of-core; query-ready file on ${STORAGE_DESC:-local NVMe}" \
  ./run.sh > "${OUT_DIR}/${MACHINE}.json"

echo "Wrote ${OUT_DIR}/${MACHINE}.json" >&2
