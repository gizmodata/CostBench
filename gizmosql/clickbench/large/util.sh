#!/usr/bin/env bash
# Shared environment, server lifecycle, and helpers for the GizmoSQL CostBench harness.
#
# The GIZMOSQL_* names are the env vars that gizmosql_server and gizmosql_client
# read natively, so exporting them here configures both.

export GIZMOSQL_HOST="${GIZMOSQL_HOST:-localhost}"
export GIZMOSQL_PORT="${GIZMOSQL_PORT:-31337}"
export GIZMOSQL_USER="${GIZMOSQL_USER:-gizmosql}"
export GIZMOSQL_PASSWORD="${GIZMOSQL_PASSWORD:-gizmosql}"

# DuckDB database file the server opens. Override per scale (e.g. clickbench_1B.db).
export DB_FILE="${DB_FILE:-clickbench.db}"

# Each shell that sources this gets its own PID file so nested scripts that only
# *use* the server (load/inflate) never clobber the lifecycle owner's PID file.
PID_FILE="/tmp/gizmosql_costbench_$$.pid"

# Start the server in the background and block until it accepts connections.
start_gizmosql() {
    nohup gizmosql_server \
        --username "${GIZMOSQL_USER}" \
        --database-filename "${DB_FILE}" \
        --storage-version latest \
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
