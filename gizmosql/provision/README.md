# Provisioning the instance

The GizmoSQL CostBench runs need a single EC2 instance whose **local NVMe** is
striped into one large volume (the DuckDB file, the downloaded parquet, and
DuckDB's spill/temp dir all live there — never the small root EBS volume).

Neither ClickBench nor CostBench ships a provisioning/RAID script, so this dir
provides a self-contained one: **[`mount_nvme.sh`](mount_nvme.sh)**.

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

The instance must be **Ubuntu** (the script is `apt`-based) with local NVMe
(`i8ge.24xlarge` for all three scales). Example with the AWS CLI, using
`mount_nvme.sh` as user-data so the RAID is built at boot:

```bash
# Latest Ubuntu 24.04 amd64 AMI in the region (must match the pricing file's region)
AMI=$(aws ssm get-parameter --region us-east-1 \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

aws ec2 run-instances --region us-east-1 \
  --instance-type i8ge.24xlarge \
  --image-id "$AMI" \
  --key-name <your-key> \
  --security-group-ids <sg-with-ssh> \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
  --user-data file://mount_nvme.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=gizmosql-costbench}]'
```

Then SSH in and run the sweep:

```bash
ssh ubuntu@<public-dns>
  # (clone or scp the CostBench fork's gizmosql/ dir up first)
  cd gizmosql
  export DATA_DIR=/mnt/nvme        # the RAID mount from mount_nvme.sh
  nohup ./run_all.sh > run_all.log 2>&1 &   # ~hours at 100B; survives disconnect
  tail -f run_all.log

# When done:
aws ec2 terminate-instances --region us-east-1 --instance-ids <id>
```

### Using GizmoData's internal launcher instead

GizmoData's private `provision-gizmosql-instance` repo can launch + mount in one
flow (`clouds/aws/launch_aws_clickbench_instance.sh i8ge.24xlarge`, then
`scripts/mount_nvme_ubuntu_xfs.sh`, which mounts at `/nvme/data`). If you use it,
set `DATA_DIR=/nvme/data` to match, and note its launcher defaults to **us-east-2**
while the pricing files here are **us-east-1** — launch in us-east-1, or update the
pricing file's `region`/`compute` to the region you actually used.
