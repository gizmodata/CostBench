#!/usr/bin/env bash
# Reduce an enriched GizmoSQL result JSON to CostBench NDJSON scoring records
# (one line per pricing tier) suitable for the _viz2 charts (render.py,
# perf_per_dollar.py, storage_cost.py).
#
# Per the CostBench "best of three" rule:
#   rt_hot   = sum over the 43 queries of the BEST (min) runtime
#   cost_hot = sum over the 43 queries of the BEST (min) per-run compute cost
#   cost_data = monthly storage cost
#
# performance-per-dollar = 1 / (rt_hot * cost_hot)   (computed by the viz)
#
# Usage: ./aggregate.sh <enriched_result.json>
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

ENRICHED="${1:?usage: aggregate.sh <enriched_result.json>}"

jq -c '
  def gib($b): ($b / 1073741824);
  def best(rows): [ rows[] | [ .[] | select(. != null) ] | (if length > 0 then min else null end) ]
                  | map(select(. != null)) | (add // 0);
  . as $d
  | $d.costs[]
  | . as $c
  | {
      id:            ($d.system + "-" + $d.machine + "-" + $c.tier),
      system:        $d.system,
      tier:          $c.tier,
      compute_model: null,
      bar_label:     ($d.system + " (" + $d.machine + ")"),
      provider:      $c.provider,
      region:        $c.region,
      machine:       $d.machine,
      cluster:       ($d.cluster_size | tostring),
      data_sz:       (((gib(($d.durable_size // $d.data_size)) * 100 | round) / 100 | tostring) + " GiB"),
      cost_data:     $c.storage_cost,
      rt_hot:        best($d.result),
      cost_hot:      best($c.compute_costs),
      nq:            ($d.result | length | tostring)
    }
' "$ENRICHED"
