# GizmoSQL — CostBench harness

A [CostBench](../README.md)-format cost-performance harness for **[GizmoSQL](https://gizmosql.com)**,
run on a **single AWS EC2 instance**.

> **Status / disclaimer.** This directory is contributed by [GizmoData](https://gizmodata.com),
> not by ClickHouse. CostBench is published by ClickHouse as a *reference* benchmark and
> [does not accept external pull requests or issues](../CONTRIBUTING.md); GizmoSQL is therefore
> **not** part of the official CostBench result set. We reproduce CostBench's published
> methodology, scripts, pricing logic, and `runtime × cost` scoring exactly so that GizmoSQL's
> single-node cost-performance can be compared on equal footing. Numbers here are GizmoData's own.

---

## What GizmoSQL is

GizmoSQL is a self-hosted [Apache Arrow Flight SQL](https://arrow.apache.org/docs/format/FlightSql.html)
server backed by [DuckDB](https://duckdb.org). You run it on hardware you choose — here, one EC2
instance — and it answers analytical SQL over a local DuckDB database. There is no cluster, no
separation of storage and compute, and no per-query service bill: the only thing you pay for is the
**seconds of EC2** the queries consume (plus a small durable copy of the data in S3).

That is the whole thesis CostBench is built to surface: **performance per dollar.** A single cheap
node bills compute at a tiny fraction of a managed warehouse's per-second rate, so even a modest
runtime can land at the top of a cost-performance ranking.

## How this maps onto CostBench

| CostBench concept            | GizmoSQL realization |
|------------------------------|----------------------|
| Workload                     | The same **43 ClickBench queries** (`clickbench/large/queries.sql`), DuckDB dialect. |
| Scales                       | **1B / 10B / (100B, TBD)** rows, inflated from the base ~100M-row `hits` dataset. |
| Native storage format        | A DuckDB database file on the instance's local **NVMe** SSD. |
| No tuning                    | Out-of-the-box DuckDB; no indexes, materialized views, or hand-tuning. |
| Hot runtime, caches disabled | Best of 3 runs; the server is restarted and the OS page cache is dropped before **each** query. |
| Real billing model           | EC2 on-demand `$/hour`, metered per second. See [Cost model](#cost-model). |
| Single comparable metric     | `cost-performance score = runtime × cost` (lower is better); `perf-per-dollar = 1/(runtime × cost)`. |

The cost math is **byte-for-byte the formula ClickHouse applied to itself** in
[`clickhouse-cloud/enrich.sh`](../clickhouse-cloud/enrich.sh) — see [Cost model](#cost-model).

## Cost model

**Compute.** CostBench's enrichment computes, per query run:

```
compute_cost = runtime_s × (compute / 3600) × (memory_size / compute_price_unit) × cluster_size
```

For a single EC2 node there is no memory-tier or cluster multiplier, so each pricing file
(`pricings/aws.<machine>.json`) sets `compute_price_unit = memory_size` and `cluster_size = 1`.
The formula then collapses to:

```
compute_cost = runtime_s × (instance_$per_hour / 3600)
```

i.e. **the real cost of the EC2 seconds the query used** — while keeping the arithmetic identical to
every other vendor in this repo. `enrich.sh` is a thin wrapper over that same jq.

**Storage — "NVMe runtime + S3 durable".** The query-ready DuckDB file lives on the instance's
**local NVMe**, which is already included in the hourly price, so it carries no separate storage
charge (and is far faster than EBS for DuckDB's scans and spills). Durability is modeled as a copy
of the **source data in Amazon S3 Standard** ($0.023/GiB-month). The harness records two sizes:

- `data_size` — the DuckDB file on NVMe (the query-ready footprint; informational).
- `durable_size` — the source data scaled to the row count; storage cost is billed on **this**.

So `storage_cost = durable_size_bytes × ($0.023 / 1 GiB)`. (Instance-store NVMe is ephemeral; the
durable system-of-record is the S3 copy, reloaded on launch.)

## What to expect (break-even analysis)

GizmoSQL's 1B/10B numbers are pending real runs (see [Reproduce](#reproduce)). But we can already
bound the result from CostBench's **own published scores** plus real EC2 prices. The lowest (best)
cloud `runtime × cost` score at each scale is ClickHouse Cloud Enterprise:

| Scale | Best cloud score (`rt × cost`) | GizmoSQL must finish 43 queries in **under** … to win |
|------:|-------------------------------:|-------------------------------------------------------|
| 1B    | 15.46 (ClickHouse 9×236 GiB)   | **302 s** on `c6a.4xlarge` · **218 s** on `r8gd.4xlarge` · **63 s** on `r8gd.metal-48xl` |
| 10B   | 284.6 (ClickHouse 20×236 GiB)  | **539 s** on `r8gd.12xlarge` · **269 s** on `r8gd.metal-48xl` |
| 100B  | 4852 (ClickHouse 20×236 GiB)   | **1113 s** on `r8gd.metal-48xl` |

The threshold is `sqrt(best_cloud_score / per_second_rate)`. For context, GizmoSQL already runs the
full 43-query suite in **3.18 s on `c8g.metal-48xl`** and **23.8 s on `c6a.4xlarge`** at the base
~100M-row scale on the [ClickBench leaderboard](https://benchmark.clickhouse.com). (Those leaderboard
anchors are warm-cache *hot* runs; this harness drops the OS page cache before each query, so treat
them as indicative scale references, not apples-to-apples timings.) Metal-class GizmoSQL clearing
~63 s at 1B (≈10× the data) is a comfortable margin; **10B is the genuinely interesting run**,
landing near the break-even line — which is exactly why we run it.

GizmoSQL's per-second compute rate vs the cloud vendors' *effective* rate at 1B (their published
`cost_hot / rt_hot`):

| System | Config | Effective $/s |
|--------|--------|--------------:|
| **GizmoSQL** | `c6a.4xlarge` | **$0.000170** |
| **GizmoSQL** | `r8gd.4xlarge` | **$0.000327** |
| **GizmoSQL** | `r8gd.metal-48xl` | **$0.003919** |
| Snowflake | Enterprise X-Small | $0.000833 |
| Databricks | Large | $0.007778 |
| Redshift | Serverless 128 RPU | $0.013297 |
| BigQuery | Enterprise 2000 slots | $0.021043 |
| ClickHouse | Enterprise 9×236 GiB | $0.028785 |

The cheap cloud tiers (Snowflake X-Small, Databricks 2X-Small) bill at a per-second rate close to
GizmoSQL's **but post 700–17,600 s on the suite**; the fast cloud tiers run in tens of seconds but
bill **24–88× more per second than GizmoSQL on `r8gd.4xlarge`** (and still 2–7× more than the
`r8gd.metal-48xl` flagship). GizmoSQL aims for the empty quadrant: a rock-bottom rate **and**
metal-class speed.

## Instances

All runs use NVMe-equipped AWS Graviton4 instances (the family GizmoSQL used for its
[1-trillion-row run](https://github.com/coiled/1trc/issues/7) — `r8gd.metal-48xl`, 11.4 TB RAID-0
NVMe, 1T rows in 129 s for **$0.51 on-demand / $0.10 spot**):

| Instance | vCPU | RAM | Local NVMe | On-demand $/hr | Suited to |
|----------|-----:|----:|-----------:|---------------:|-----------|
| `r8gd.4xlarge`     | 16  | 128 GiB  | 950 GB  | $1.17568 | 1B (~270 GB DB) |
| `r8gd.12xlarge`    | 48  | 384 GiB  | 2.85 TB | $3.527   | 10B (~2.7 TB DB) |
| `r8gd.metal-48xl`  | 192 | 1536 GiB | 11.4 TB | $14.108  | 10B / 100B |

> **100B caveat.** At 100B rows the DuckDB file is ≈27 TB, larger than one instance's NVMe, so 100B
> needs striped EBS, multiple disks, or a larger box — and is deferred until 1B/10B are in.

## Layout

```
gizmosql/
├── README.md                  – this file
├── enrich.sh                  – raw result + pricing → enriched (CostBench cost schema)
├── aggregate.sh               – enriched → NDJSON scoring record for ../_viz2
├── pricings/
│   └── aws.<machine>.json      – EC2 on-demand pricing in CostBench's pricing schema
├── clickbench/large/
│   ├── create.sql              – hits schema (DuckDB dialect)
│   ├── queries.sql             – the 43 ClickBench queries
│   ├── util.sh                 – env + server start/stop + scalar helpers
│   ├── load_once_from_url.sh   – download + load the base ~100M hits
│   ├── inflate_until.sh        – double the table to the target row count
│   ├── run.sh                  – 43 queries × 3, emit raw result JSON
│   ├── benchmark.sh            – end-to-end driver for one scale/machine
│   └── results_{1B,10B,100B}/  – raw per-query runtimes
└── results_{1B,10B,100B}/      – enriched (cost) results
```

## Reproduce

On a fresh Ubuntu EC2 instance (`INSTALL=1` installs deps + GizmoSQL via the one-line installer):

```bash
cd gizmosql/clickbench/large

# Example: 1B rows on r8gd.4xlarge
MACHINE=r8gd.4xlarge MEMORY_GIB=128 SCALE=1B TARGET_ROWS=1000000000 INSTALL=1 ./benchmark.sh
#   → writes results_1B/r8gd.4xlarge.json   (raw per-query runtimes)

# Example: 10B rows on r8gd.metal-48xl
MACHINE=r8gd.metal-48xl MEMORY_GIB=1536 SCALE=10B TARGET_ROWS=10000000000 ./benchmark.sh
```

Then enrich with the matching pricing file and reduce to a scoring record:

```bash
cd gizmosql
./enrich.sh   clickbench/large/results_1B/r8gd.4xlarge.json \
              pricings/aws.r8gd.4xlarge.json \
              results_1B/r8gd.4xlarge.json
./aggregate.sh results_1B/r8gd.4xlarge.json >> results_1B/scoring.ndjson

# Chart it with CostBench's own visualizers:
python ../_viz2/perf_per_dollar.py --no-title -o ppd_1B.png < results_1B/scoring.ndjson
python ../_viz2/render.py          --no-title -o scatter_1B.png < results_1B/scoring.ndjson
```

The scripts are bash-3.2 compatible, so the harness also runs on macOS for development/testing.

## Results

| Scale | Instance | rt_hot (s) | cost_hot ($) | storage ($/mo) | perf/$ vs best cloud |
|------:|----------|-----------:|-------------:|---------------:|----------------------|
| 1B    | _r8gd.4xlarge_     | _pending_ | _pending_ | _pending_ | _pending_ |
| 1B    | _r8gd.metal-48xl_  | _pending_ | _pending_ | _pending_ | _pending_ |
| 10B   | _r8gd.metal-48xl_  | _pending_ | _pending_ | _pending_ | _pending_ |

_(Filled in as the runs complete.)_

## Honest caveats

- **Single node ≠ managed warehouse.** GizmoSQL is one box you operate. The cloud comparators bundle
  elasticity, multi-tenancy, high availability, durability, and zero-ops that the EC2 hourly price
  does **not** include. This compares *compute cost-performance for a single-node analytical
  workload*, not feature parity.
- **Concurrency.** These are single-stream best-of-3 runtimes, like ClickBench. A single GizmoSQL
  node serves concurrent queries from one process; this benchmark does not measure high concurrency.
- **Ephemeral NVMe.** The query-ready file is on instance-store NVMe (gone on stop); durability is
  the modeled S3 copy. Numbers assume you reload from S3 on launch.
- **Not affiliated with or endorsed by ClickHouse.** This is an independent reproduction of their
  open methodology.
