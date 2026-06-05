#!/usr/bin/env bash
# Run the full GizmoSQL CostBench sweep on one instance: for each scale,
#   benchmark.sh (load + inflate + run)  →  enrich.sh (cost)  →  aggregate.sh (NDJSON)
#
# It's a multi-hour job at 100B, so run it detached:
#   nohup ./run_all.sh > run_all.$(date +%Y%m%d_%H%M%S).log 2>&1 &
#   tail -f run_all.*.log
#
# Required env:
#   MACHINE      instance label + pricing-file key, e.g. i8ge.24xlarge
#                (must have a matching pricings/aws.<MACHINE>.json)
#   MEMORY_GIB   instance RAM in GiB (must equal that pricing file's memory_size)
#   DATA_DIR     ABSOLUTE NVMe mount path; DB + parquet + DuckDB spill all live here
#                (created by provision/mount_nvme.sh)
#
# Optional env:
#   SCALES        space-separated subset, e.g. "1B 10B"   (default "1B 10B 100B")
#   INSTALL=1     install deps + GizmoSQL on the first scale only
#   MEMORY_LIMIT  DuckDB memory limit, e.g. "90%"         (passed through)
set -euo pipefail
cd "$(dirname "$0")"   # gizmosql/

MACHINE="${MACHINE:?set MACHINE (e.g. i8ge.24xlarge)}"
MEMORY_GIB="${MEMORY_GIB:?set MEMORY_GIB (instance RAM in GiB)}"
DATA_DIR="${DATA_DIR:?set DATA_DIR to the NVMe mount (e.g. /mnt/nvme)}"
export MACHINE MEMORY_GIB DATA_DIR
SCALES="${SCALES:-1B 10B 100B}"

PRICING="pricings/aws.${MACHINE}.json"
[ -f "$PRICING" ] || { echo "ERROR: missing pricing file $PRICING" >&2; exit 1; }

rows_for() {
  case "$1" in
    1B)   echo 1000000000 ;;
    10B)  echo 10000000000 ;;
    100B) echo 100000000000 ;;
    *)    echo "ERROR: unknown scale '$1' (use 1B|10B|100B)" >&2; return 1 ;;
  esac
}

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

RUN_INSTALL="${INSTALL:-0}"   # install only on the first scale
for SCALE in $SCALES; do
  TARGET_ROWS="$(rows_for "$SCALE")"
  echo "===== [$(stamp)] $SCALE ($TARGET_ROWS rows) on $MACHINE ====="

  # 1) generate + run  ->  raw per-query runtimes
  INSTALL="$RUN_INSTALL" SCALE="$SCALE" TARGET_ROWS="$TARGET_ROWS" \
    clickbench/large/benchmark.sh
  RUN_INSTALL=0

  RAW="clickbench/large/results_${SCALE}/${MACHINE}.json"
  ENRICHED="results_${SCALE}/${MACHINE}.json"
  mkdir -p "results_${SCALE}"

  # 2) enrich with the instance pricing  ->  CostBench cost schema
  ./enrich.sh "$RAW" "$PRICING" "$ENRICHED"

  # 3) reduce to an NDJSON scoring record for ../_viz2 (one line; overwrite on re-run)
  ./aggregate.sh "$ENRICHED" > "results_${SCALE}/scoring.ndjson"
  echo "[$(stamp)] $SCALE done:"
  ./aggregate.sh "$ENRICHED"
  echo
done

echo "===== [$(stamp)] sweep complete ====="
for SCALE in $SCALES; do echo "  results_${SCALE}/${MACHINE}.json  (+ scoring.ndjson)"; done
echo
echo "To chart GizmoSQL against the cloud vendors, cat the scoring records together and feed _viz2:"
echo "  cat results_1B/scoring.ndjson ../<vendor>/.../results_1B/*.ndjson \\"
echo "    | python ../_viz2/perf_per_dollar.py --no-title -o ppd_1B.png"
