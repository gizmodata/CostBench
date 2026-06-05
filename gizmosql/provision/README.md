# Provisioning the instance

The GizmoSQL CostBench runs need a single EC2 instance whose **local NVMe** is
striped into one large volume (the DuckDB file, the downloaded parquet, and
DuckDB's spill/temp dir all live there — never the small root EBS volume).

Neither ClickBench nor CostBench ships a provisioning/RAID script, so this dir
provides self-contained ones: **[`provision.sh`](provision.sh)** (launch the
instance) + **[`mount_nvme.sh`](mount_nvme.sh)** (RAID-0 the NVMe, wired in as
user-data) + **[`teardown.sh`](teardown.sh)**.

## `mount_nvme.sh`

RAID-0s **all** local instance-store NVMe devices into one XFS volume and mounts
it. On an `i8ge.24xlarge` that's 8 × 7.5 TB → ~60 TB at `/mnt/nvme`. It:

- waits for every NVMe device to enumerate before building the array,
- excludes the root EBS volume (by NVMe model string),
- RAIDs a **dynamic** device count (works on any instance-store size),
- is idempotent (skips if already mounted),
- persists the array (`mdadm.conf` + initramfs) and mount (fstab, by UUID).

```bash
sudo bash mount_nvme.sh [MOUNT_POINT] [OWNER]   # defaults: /mnt/nvme  ubuntu
```

> **Ephemeral.** Instance-store NVMe is wiped on stop/start and on terminate; the
> persistence above only survives a *reboot*. The durable system-of-record is the
> source data in S3 (see the [cost model](../README.md#cost-model)).

## Launch → mount → run → teardown

`provision.sh` launches an Ubuntu `i8ge.24xlarge` (us-east-1 by default, to match
the pricing files) and wires `mount_nvme.sh` in as **user-data**, so the NVMe
RAID-0 is built at boot. Config lives in `.env` (gitignored) — copy `.env.example`
and fill in AWS creds (or `AWS_PROFILE`) and your `KEY_NAME`:

```bash
cp .env.example .env && "$EDITOR" .env    # set AWS creds + KEY_NAME
./provision.sh                            # launches; prints the public DNS + next steps
```

If you don't pass `SECURITY_GROUP_IDS`, it finds-or-creates an SSH-only security
group from your current IP. Then SSH in, point `DATA_DIR` at the mount, and run
the sweep:

```bash
ssh ubuntu@<public-dns>
  df -h /mnt/nvme && cat /proc/mdstat       # confirm the ~60 TB RAID-0 mounted
  # clone or scp the CostBench fork's gizmosql/ dir up first
  cd gizmosql
  export DATA_DIR=/mnt/nvme
  MACHINE=i8ge.24xlarge MEMORY_GIB=768 INSTALL=1 nohup ./run_all.sh > run_all.log 2>&1 &
  tail -f run_all.log                       # ~hours at 100B; survives disconnect

# When done (terminates by Name tag, or pass an instance id):
./teardown.sh
```

### Using GizmoData's internal launcher instead

GizmoData's private `provision-gizmosql-instance` repo can launch + mount in one
flow (`clouds/aws/launch_aws_clickbench_instance.sh i8ge.24xlarge`, then
`scripts/mount_nvme_ubuntu_xfs.sh`, which mounts at `/nvme/data`). If you use it,
set `DATA_DIR=/nvme/data` to match, and note its launcher defaults to **us-east-2**
while the pricing files here are **us-east-1** — launch in us-east-1, or update the
pricing file's `region`/`compute` to the region you actually used.
