# GizmoSQL — CostBench harness

A [CostBench](../README.md)-format cost-performance harness for **[GizmoSQL](https://gizmosql.com)**,
run on a **single AWS EC2 instance**.

**Measured result:** on one `i8ge.24xlarge`, GizmoSQL takes **#1 cost-performance at 1B**
(~4× better than ClickHouse Cloud, CostBench's own winner) and **#2 at 10B** (ahead of every cloud
warehouse except ClickHouse Cloud). Details in [Results](#results).

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
| Scales                       | **1B / 10B / 100B** rows, inflated from the base ~100M-row `hits` dataset. |
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

Measured **1B and 10B** results are in the [Results](#results) section below — and they tracked this
break-even reasoning closely (100B was skipped; see Results). The reasoning, derivable up front from
CostBench's **own published scores** plus real EC2 prices: both scales run on one **`i8ge.24xlarge`**
(96-core Graviton4, single NUMA node, 60 TB local NVMe, $11.39/hr → **$0.003164/s**). The lowest
(best) cloud `runtime × cost` score at each scale is ClickHouse Cloud Enterprise — the bar GizmoSQL
has to clear:

| Scale | Best cloud score (`rt × cost`) | GizmoSQL on `i8ge.24xlarge` must finish 43 queries in **under** … |
|------:|-------------------------------:|-------------------------------------------------------------------|
| 1B    | 15.46 (ClickHouse 9×236 GiB)   | **70 s**   |
| 10B   | 284.6 (ClickHouse 20×236 GiB)  | **300 s**  |
| 100B  | 4852 (ClickHouse 20×236 GiB)   | **1238 s** (~20.6 min) |

The threshold is `sqrt(best_cloud_score / per_second_rate)`. For context, GizmoSQL runs the full
43-query suite in **3.18 s on `c8g.metal-48xl`** (192-core) and **23.8 s on `c6a.4xlarge`** at the
base ~100M-row scale on the [ClickBench leaderboard](https://benchmark.clickhouse.com). (Those are
warm-cache *hot* leaderboard runs; this harness drops the OS page cache before each query, so treat
them as indicative scale references, not apples-to-apples.) So:

- **1B** has the tightest bar (70 s) — a small dataset on a box sized for 100B — but 96 single-socket
  cores should clear it comfortably. A cheaper instance (`r8gd.4xlarge`, $0.000327/s) would give 1B
  far more headroom if you later split it off.
- **10B is the genuinely interesting run**, landing near the 300 s break-even line.
- **100B** is the hardest: 27 TB out-of-core on 768 GiB RAM, ~20 min to beat the cloud — runnable on
  this box (60 TB NVMe), but the least certain to win cost-performance.

GizmoSQL's per-second rate on `i8ge.24xlarge` ($0.003164/s) vs the cloud vendors' *effective* rate
at 1B (their published `cost_hot / rt_hot`):

| System | Config | Effective $/s |
|--------|--------|--------------:|
| **GizmoSQL** | `i8ge.24xlarge` | **$0.003164** |
| Snowflake | Enterprise X-Small | $0.000833 |
| Databricks | Large | $0.007778 |
| Redshift | Serverless 128 RPU | $0.013297 |
| BigQuery | Enterprise 2000 slots | $0.021043 |
| ClickHouse | Enterprise 9×236 GiB | $0.028785 |

The *fast* cloud tiers bill **2.5–9× more per second** than GizmoSQL on `i8ge.24xlarge`; the *cheap*
tiers (Snowflake X-Small, Databricks 2X-Small, ~$0.0008/s) undercut it on rate but post
**700–17,600 s** on the suite — 1–2 orders of magnitude slower. GizmoSQL aims for the empty quadrant:
a competitive rate **and** fast single-node speed. (Smaller single-socket instances push the rate
~10× lower again — e.g. `r8gd.4xlarge` at $0.000327/s — the cost-performance play for the smaller
scales if you split them off this box.)

## Instances

All three scales run on a single **`i8ge.24xlarge`** — AWS's storage-dense Graviton4 instance:

| Instance | vCPU | RAM | NUMA | Local NVMe | On-demand $/hr | Used for |
|----------|-----:|----:|:----:|-----------:|---------------:|----------|
| `i8ge.24xlarge` | 96 | 768 GiB | **1 socket / 1 node** | **60 TB** (8 × 7.5 TB) | $11.39 | 1B / 10B / 100B |

Why this one box:

- **Storage.** 60 TB of local NVMe holds even the 100B DuckDB file (≈27 TB) with ~2× headroom for
  query spill — so 100B runs on a single node, no striped EBS or larger box needed.
- **Single NUMA node.** 96 cores = one Graviton4 socket. DuckDB isn't NUMA-pinning-aware, so the
  2-socket sizes (`.48xlarge` / `.metal-48xl`, 192 vCPU = 2 NUMA nodes) pay a cross-socket bandwidth
  penalty on these scan-heavy queries and scale sub-linearly. The single-socket `.24xlarge` avoids
  that — and at half the price its cost-performance break-even is √2 wider, so the bigger box would
  have to be >1.41× faster just to break even (which DuckDB rarely delivers across sockets).
- **Lineage.** Same Graviton4 + local-NVMe lineage as the `r8gd.metal-48xl` GizmoSQL used for its
  [1-trillion-row run](https://github.com/coiled/1trc/issues/7) (1T rows in 129 s on NVMe).

> **Per-scale optimization (optional).** Running everything on one 100B-sized box is simplest, but a
> cheaper single-socket instance gives the smaller scales more cost-performance headroom — e.g.
> `r8gd.4xlarge` ($1.18/hr) for 1B or `r8gd.24xlarge` ($7.05/hr) for 10B. Pricing files for those are
> included (`pricings/aws.*.json`) if you want to split scales across instances.

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

On a fresh Ubuntu `i8ge.24xlarge` with the local NVMe RAID-0'd and mounted (see
[`provision/`](provision/README.md)), the whole sweep is one command:

```bash
cd gizmosql
nohup ./run_all.sh > run_all.log 2>&1 &    # ~hours at 100B; survives disconnect
tail -f run_all.log
```

`run_all.sh` auto-detects the **instance type** (EC2 IMDS), reads **`MEMORY_GIB`** from the matching
pricing file, defaults **`DATA_DIR`** to `/mnt/nvme` when it's mounted, **installs** GizmoSQL + deps
if missing, then for each scale runs `benchmark.sh → enrich.sh → aggregate.sh` — writing
`results_<SCALE>/<machine>.json` (enriched) and `results_<SCALE>/scoring.ndjson`. Override any of
`MACHINE`, `MEMORY_GIB`, `DATA_DIR`, `SCALES` (e.g. `SCALES="1B 10B"`), `MEMORY_LIMIT`, or `INSTALL=1`
via env. The query-ready DuckDB file, the downloaded parquet, and DuckDB's spill/temp dir all live
under `DATA_DIR` (the NVMe mount), so nothing large touches the small root EBS volume.

Rough wall-clock to **build** each dataset (DuckDB self-insert ≈ 5–15M rows/s; `load_time` is
CostBench's write-side metric and does **not** affect the read-side score):

| Scale | Data generation | DB size on NVMe |
|------:|-----------------|-----------------|
| 1B    | ~4–5 min   | ~270 GB |
| 10B   | ~15–30 min | ~2.7 TB |
| 100B  | ~3–6 hours | ~27 TB |

<details><summary>Running one scale by hand (instead of run_all.sh)</summary>

```bash
cd gizmosql/clickbench/large
export DATA_DIR=/mnt/nvme
MACHINE=i8ge.24xlarge MEMORY_GIB=768 SCALE=1B TARGET_ROWS=1000000000 INSTALL=1 ./benchmark.sh
cd .. && ./enrich.sh clickbench/large/results_1B/i8ge.24xlarge.json \
                     pricings/aws.i8ge.24xlarge.json results_1B/i8ge.24xlarge.json
./aggregate.sh results_1B/i8ge.24xlarge.json >> results_1B/scoring.ndjson
```
</details>

Then chart it with CostBench's own visualizers:

```bash
python ../_viz2/perf_per_dollar.py --no-title -o ppd_1B.png     < results_1B/scoring.ndjson
python ../_viz2/render.py          --no-title -o scatter_1B.png < results_1B/scoring.ndjson
```

The scripts are bash-3.2 compatible, so the harness also runs on macOS for development/testing.

## Results

Measured on a single `i8ge.24xlarge` (us-east-1, on-demand $11.39/hr), best of 3 per query, OS page
cache dropped before each query. Score = `runtime × cost` (lower is better); rank is across GizmoSQL
plus the five CostBench cloud warehouses (all tiers) at that scale.

| Scale | rt_hot (s) | cost_hot ($) | score (rt×cost) | storage ($/mo) | cost-performance result |
|------:|-----------:|-------------:|----------------:|---------------:|-------------------------|
| 1B    | 34.1  | 0.108 | **3.7**  | 3.17  | **#1** — 4.2× better than ClickHouse Cloud (next best); 8–140× better than every BigQuery/Redshift/Snowflake/Databricks config |
| 10B   | 597.3 | 1.89  | **1129** | 31.66 | **#2** — beats every cloud warehouse **except** ClickHouse Cloud (4.0× behind it; 1.7–210× ahead of all the others) |
| 100B  | —     | —     | —        | —     | not run — a ~27 TB DuckDB file is far past one node's 768 GiB RAM (heavily out-of-core); the single-node story fades beyond ~10B |

**Takeaway.** A single $11.39/hr node **wins 1B cost-performance outright** (~4× better than
ClickHouse Cloud, the benchmark's own winner) and takes **2nd at 10B** — ahead of every cloud
warehouse except ClickHouse. The crossover is the single-node RAM ceiling: at 1B (~270 GB) the
working set stays fast; by 10B (~2.7 TB) DuckDB is heavily out-of-core on 768 GiB RAM, so runtime
scales super-linearly while ClickHouse's multi-node cluster scales sub-linearly. Storage is the only
axis where GizmoSQL trails (its durable source copy is larger than ClickHouse's compressed
MergeTree) — a small, secondary monthly cost.

Raw scoring records: [`results_1B/scoring.ndjson`](results_1B/scoring.ndjson) ·
[`results_10B/scoring.ndjson`](results_10B/scoring.ndjson); enriched per-query costs in
`results_<scale>/i8ge.24xlarge.json`.

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
