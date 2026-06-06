#!/usr/bin/env bash
# Run the full GizmoSQL CostBench sweep on one instance: for each scale,
#   benchmark.sh (load + inflate + run)  →  enrich.sh (cost)  →  aggregate.sh (NDJSON)
#
# It's a multi-hour job at 100B, so run it detached:
#   nohup ./run_all.sh > run_all.$(date +%Y%m%d_%H%M%S).log 2>&1 &
#   tail -f run_all.*.log
#
# Auto-detects the box on EC2; override any of these via env:
#   MACHINE      pricing-file key / instance label. Default: the EC2 instance type
#                from IMDS (e.g. i8ge.24xlarge). Needs pricings/aws.<MACHINE>.json
#   MEMORY_GIB   instance RAM in GiB. Default: memory_size from that pricing file
#   DATA_DIR     ABSOLUTE NVMe mount path (DB + parquet + DuckDB spill live here).
#                Default: /mnt/nvme if it is a mountpoint (provision/mount_nvme.sh)
#
# Optional env:
#   SCALES        space-separated subset, e.g. "1B 10B"   (default "1B 10B 100B")
#   INSTALL=1     force a (re)install of GizmoSQL + deps (auto-installed if missing)
#   MEMORY_LIMIT  DuckDB memory limit, e.g. "90%"         (passed through)
set -euo pipefail
cd "$(dirname "$0")"   # gizmosql/
export PATH="$HOME/.local/bin:$PATH"   # the GizmoSQL one-line installer drops binaries here

# Query EC2 IMDSv2 (falls back to v1); empty off-EC2 — used to auto-detect MACHINE.
imds() {
  local tok
  tok="$(curl -fsS --max-time 2 -X PUT 'http://169.254.169.254/latest/api/token' \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 120' 2>/dev/null || true)"
  if [ -n "$tok" ]; then
    curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $tok" \
         "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
  else
    curl -fsS --max-time 2 "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
  fi
}

# MACHINE: env, else the EC2 instance type (e.g. i8ge.24xlarge).
MACHINE="${MACHINE:-$(imds instance-type)}"
[ -n "$MACHINE" ] || { echo "ERROR: set MACHINE (could not auto-detect the EC2 instance type)." >&2; exit 1; }

PRICING="pricings/aws.${MACHINE}.json"
[ -f "$PRICING" ] || { echo "ERROR: no pricing file ${PRICING} for instance ${MACHINE}." >&2; exit 1; }

# MEMORY_GIB: env, else memory_size from the pricing file (matches what enrich.sh
# bills against). Parsed without jq, which may not be installed yet on a fresh box.
MEMORY_GIB="${MEMORY_GIB:-$(sed -n 's/.*"memory_size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PRICING" | head -1)}"
[ -n "$MEMORY_GIB" ] || { echo "ERROR: set MEMORY_GIB (couldn't read memory_size from ${PRICING})." >&2; exit 1; }

# DATA_DIR: env, else /mnt/nvme if it's actually a mountpoint (don't risk the root vol).
if [ -z "${DATA_DIR:-}" ]; then
  if mountpoint -q /mnt/nvme 2>/dev/null; then DATA_DIR=/mnt/nvme
  else echo "ERROR: set DATA_DIR to the NVMe mount (e.g. /mnt/nvme; nothing mounted there)." >&2; exit 1; fi
fi

export MACHINE MEMORY_GIB DATA_DIR
SCALES="${SCALES:-1B 10B 100B}"
echo "Machine: ${MACHINE}   Memory: ${MEMORY_GIB} GiB   Data dir: ${DATA_DIR}   Scales: ${SCALES}"

rows_for() {
  case "$1" in
    1B)   echo 1000000000 ;;
    10B)  echo 10000000000 ;;
    100B) echo 100000000000 ;;
    *)    echo "ERROR: unknown scale '$1' (use 1B|10B|100B)" >&2; return 1 ;;
  esac
}

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Install GizmoSQL + the deps the harness needs if they're missing (INSTALL=1
# forces a reinstall). Same one-line installer benchmark.sh uses; doing it here,
# once, means every scale's benchmark.sh inherits the binaries on PATH.
ensure_installed() {
  if [ "${INSTALL:-0}" = "1" ] || ! command -v gizmosql_server >/dev/null 2>&1; then
    echo "[$(stamp)] installing GizmoSQL + deps..."
    sudo apt-get update -y
    sudo apt-get install -y curl unzip wget jq netcat-openbsd
    curl -fsSL https://install.gizmosql.com/install.sh | sh
  fi
  command -v jq >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y jq; }
}
ensure_installed

for SCALE in $SCALES; do
  TARGET_ROWS="$(rows_for "$SCALE")"
  echo "===== [$(stamp)] $SCALE ($TARGET_ROWS rows) on $MACHINE ====="

  # 1) generate + run  ->  raw per-query runtimes (install already handled above)
  INSTALL=0 SCALE="$SCALE" TARGET_ROWS="$TARGET_ROWS" \
    clickbench/large/benchmark.sh

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
