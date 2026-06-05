#!/usr/bin/env bash
# Shared environment, server lifecycle, and helpers for the GizmoSQL CostBench harness.
#
# The GIZMOSQL_* names are the env vars that gizmosql_server and gizmosql_client
# read natively, so exporting them here configures both.

export GIZMOSQL_HOST="${GIZMOSQL_HOST:-localhost}"
export GIZMOSQL_PORT="${GIZMOSQL_PORT:-31337}"
export GIZMOSQL_USER="${GIZMOSQL_USER:-gizmosql}"
export GIZMOSQL_PASSWORD="${GIZMOSQL_PASSWORD:-gizmosql}"

# Data directory — point this at the instance's local NVMe mount on EC2 (e.g.
# /mnt/nvme). The DuckDB database file, the downloaded parquet, and DuckDB's
# spill/temp directory all live under it, so nothing large ever lands on the
# small root EBS volume. Use an ABSOLUTE path for real runs.
export DATA_DIR="${DATA_DIR:-.}"

# DuckDB database file the server opens. Override per scale (e.g. clickbench_1B.db).
export DB_FILE="${DB_FILE:-${DATA_DIR}/clickbench.db}"

# Where DuckDB spills large out-of-core queries (sorts / hash joins / aggregations).
# MUST be on the big NVMe mount for 10B/100B, or the root volume fills and queries
# crash. Applied via a `SET temp_directory` startup command (see start_gizmosql).
export DUCKDB_TEMP_DIR="${DUCKDB_TEMP_DIR:-${DATA_DIR}/duckdb_tmp}"

# Optional DuckDB memory limit, passed to gizmosql_server's --memory-limit flag
# (e.g. "700GB", "90%"). Empty leaves DuckDB's default (~80% of RAM).
export MEMORY_LIMIT="${MEMORY_LIMIT:-}"

# Each shell that sources this gets its own PID file so nested scripts that only
# *use* the server (load/inflate) never clobber the lifecycle owner's PID file.
PID_FILE="/tmp/gizmosql_costbench_$$.pid"

# Start the server in the background and block until it accepts connections.
start_gizmosql() {
    mkdir -p "$(dirname "${DB_FILE}")" "${DUCKDB_TEMP_DIR}" 2>/dev/null || true
    # Point DuckDB's spill/temp directory at the NVMe mount via a startup SET.
    local init_sql="SET temp_directory='${DUCKDB_TEMP_DIR}';"
    [ -n "${SERVER_INIT_SQL:-}" ] && init_sql="${init_sql} ${SERVER_INIT_SQL}"
    # Optional DuckDB memory limit (passthrough flag; latest gizmosql_server).
    # Unquoted on purpose so an empty value expands to no argument (values like
    # "700GB"/"90%" contain no spaces); keeps it bash-3.2 + `set -u` safe.
    local mem_flag=""
    [ -n "${MEMORY_LIMIT:-}" ] && mem_flag="--memory-limit ${MEMORY_LIMIT}"
    nohup gizmosql_server \
        --username "${GIZMOSQL_USER}" \
        --database-filename "${DB_FILE}" \
        --storage-version latest \
        --init-sql-commands "${init_sql}" \
        ${mem_flag} \
        --print-queries >> gizmosql_server.log 2>&1 &
    echo $! > "${PID_FILE}"
    echo "Waiting for gizmosql_server on ${GIZMOSQL_HOST}:${GIZMOSQL_PORT}..." >&2
    # Bounded wait with a liveness check: if the server dies during startup
    # (bad DB file, port in use, missing binary) we fail fast instead of
    # spinning forever — important for unattended runs.
    local waited=0
    until nc -z "${GIZMOSQL_HOST}" "${GIZMOSQL_PORT}" 2>/dev/null; do
        if ! kill -0 "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null; then
            echo "ERROR: gizmosql_server exited during startup. Last log lines:" >&2
            tail -n 20 gizmosql_server.log >&2 2>/dev/null || true
            return 1
        fi
        waited=$((waited + 1))
        if [ "${waited}" -ge "${SERVER_START_TIMEOUT:-180}" ]; then
            echo "ERROR: gizmosql_server did not become ready within ${SERVER_START_TIMEOUT:-180}s" >&2
            return 1
        fi
        sleep 1
    done
    echo "gizmosql_server ready (PID $(cat "${PID_FILE}"))" >&2
}

# Stop the server started by this shell.
stop_gizmosql() {
    if [ -f "${PID_FILE}" ]; then
        local pid; pid="$(cat "${PID_FILE}")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping gizmosql_server (PID: $pid)..." >&2
            kill "$pid"; wait "$pid" 2>/dev/null
        fi
        rm -f "${PID_FILE}"
    fi
}

# Run a query and return the first column of the first row, no header/banner.
# Used for scalar reads (row counts, version) against a running server.
gizmosql_scalar() {
    gizmosql_client --quiet --csv --no-header --command "$1" 2>/dev/null \
        | head -n 1 | tr -d '"[:space:]'
}

# Current row count of the hits table.
hits_rows() { gizmosql_scalar "SELECT count(*) FROM hits;"; }
