#!/usr/bin/env bash
# Load the base ClickBench 'hits' dataset (~100M rows) into the running GizmoSQL
# server's database. Assumes a server is ALREADY running (benchmark.sh owns the
# server lifecycle). Downloads the parquet first if HITS_PARQUET is a local path
# that does not yet exist.
#
# Env:
#   HITS_PARQUET  local file (or http URL) to read           [hits.parquet]
#   HITS_URL      download source when HITS_PARQUET is missing
#                 [https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet]
set -euo pipefail
cd "$(dirname "$0")"

HITS_PARQUET="${HITS_PARQUET:-${DATA_DIR:-.}/hits.parquet}"
HITS_URL="${HITS_URL:-https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet}"

if [[ "$HITS_PARQUET" != http* && ! -f "$HITS_PARQUET" ]]; then
  echo "Downloading $HITS_URL -> $HITS_PARQUET ..." >&2
  wget --continue --progress=dot:giga "$HITS_URL" -O "$HITS_PARQUET"
fi

# Typed schema (DuckDB dialect).
gizmosql_client --quiet --bail --file create.sql

# Load with date/time transforms: the parquet stores EventDate as an int (days)
# and the *Time columns as epoch seconds, so convert to DATE/TIMESTAMP on insert.
gizmosql_client --quiet --bail --command "
INSERT INTO hits BY NAME
SELECT * REPLACE (
    make_date(EventDate) AS EventDate,
    epoch_ms(EventTime * 1000) AS EventTime,
    epoch_ms(ClientEventTime * 1000) AS ClientEventTime,
    epoch_ms(LocalEventTime * 1000) AS LocalEventTime)
FROM read_parquet('${HITS_PARQUET}', binary_as_string=True);
"
