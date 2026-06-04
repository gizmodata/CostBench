#!/usr/bin/env bash
# Enrich a raw GizmoSQL result JSON with CostBench-format cost calculations,
# reusing ClickHouse Cloud's EXACT compute/storage cost formula
# (see clickhouse-cloud/enrich.sh in this repo):
#
#   compute cost per run   = runtime_s * (compute / 3600)
#                                      * (memory_size / compute_price_unit)
#                                      * cluster_size
#   storage cost (monthly) = data_size_bytes * (storage / storage_price_unit)
#
# For GizmoSQL the pricing file sets compute_price_unit = memory_size, so the
# memory ratio is 1.0 and `compute` is simply the EC2 instance's $/hour and
# cluster_size is 1. That reduces the formula to runtime_s * ($hour / 3600) --
# the real cost of the seconds of EC2 the query consumed -- while keeping the
# math byte-for-byte identical to the one ClickHouse applied to itself.
#
# Usage: ./enrich.sh <raw_result.json> <pricing.json> [output.json]
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

RESULT="${1:?usage: enrich.sh <raw_result.json> <pricing.json> [output.json]}"
PRICING="${2:?usage: enrich.sh <raw_result.json> <pricing.json> [output.json]}"
OUT="${3:-/dev/stdout}"

jq -n --slurpfile r "$RESULT" --slurpfile p "$PRICING" '
  ($r[0]) as $res
  | ($p[0]) as $price
  # Storage is billed on the durable S3 copy of the source data when present,
  # falling back to data_size for vendors whose engine file IS the billed store.
  | (($res.durable_size // $res.data_size) | tonumber) as $bytes
  | ($price.memory_size | tonumber) as $memory_size
  | ($price.cluster_size | tonumber) as $cluster_size
  | $res + {
      provider: $price.provider,
      region:   $price.region,
      costs: [
        $price.tier[]
        | . as $tier
        | (($tier.storage | tonumber) / ($tier.storage_price_unit | tonumber)) as $ppb
        | {
            tier:     $tier.name,
            provider: $price.provider,
            region:   $price.region,
            compute_costs: [
              $res.result[]
              | [ .[]
                  | if . == null then null
                    else ( . * (($tier.compute | tonumber) / 3600)
                             * ($memory_size / ($tier.compute_price_unit | tonumber))
                             * $cluster_size )
                    end ]
            ],
            storage_cost: ($bytes * $ppb),
            storage_costs: [ {
              model:  ($tier.storage_model // "block"),
              term:   "active",
              period: "monthly",
              price_per_byte: $ppb,
              bytes:  $bytes,
              estimated_cost: ($bytes * $ppb),
              pricing_base: {
                price_usd:        ($tier.storage | tonumber),
                price_unit:       "byte_month",
                price_unit_bytes: ($tier.storage_price_unit | tonumber),
                notes:            ($tier.storage_notes // "")
              }
            } ],
            pricing_base: {
              compute:            ($tier.compute | tonumber),
              compute_price_unit: ($tier.compute_price_unit | tonumber),
              storage:            ($tier.storage | tonumber),
              storage_price_unit: ($tier.storage_price_unit | tonumber)
            }
          }
      ]
    }
' > "$OUT"
