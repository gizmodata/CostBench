#!/usr/bin/env bash
# Build a RAID-0 across ALL local NVMe instance-store SSDs and mount it, for the
# GizmoSQL CostBench runs. Run as root on the freshly-booted instance:
#
#   sudo bash mount_nvme.sh [MOUNT_POINT] [OWNER]
#
# or drop it in as EC2 user-data (it then runs as root at boot).
#
# Defaults: MOUNT_POINT=/mnt/nvme  OWNER=ubuntu
#
# On an i8ge.24xlarge this RAID-0s all 8 x 7.5 TB instance-store devices into one
# ~60 TB XFS volume. The root EBS volume is excluded by its NVMe model string.
# Afterwards:  export DATA_DIR=<MOUNT_POINT>  before running the benchmark.
#
# Hardened vs a one-shot mount: waits for all devices to enumerate, RAIDs a
# dynamic device count, is idempotent (skips if already mounted), and persists
# both the array (mdadm.conf + initramfs) and the mount (fstab by UUID).
#
# NOTE: instance-store NVMe is EPHEMERAL — wiped on stop/start and on terminate.
# This persistence only survives a *reboot*; it is not durability. The durable
# system-of-record is the source data in S3 (see ../README.md cost model).
set -euo pipefail

MOUNT_POINT="${1:-${MOUNT_POINT:-/mnt/nvme}}"
OWNER="${2:-${OWNER:-ubuntu}}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash mount_nvme.sh)." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nvme-cli mdadm xfsprogs

# Enumerate local instance-store NVMe devices. The EBS root volume reports model
# "Amazon Elastic Block Store" and is therefore excluded by this filter.
list_devices() {
  nvme list 2>/dev/null | awk '/Amazon EC2 NVMe Instance Storage/ {print $1}' | sort | tr '\n' ' '
}

# Wait (up to ~30s) until the device count stops growing, so a slow-to-appear
# disk can't silently yield a smaller-than-expected array.
prev=-1
for _ in $(seq 1 30); do
  n="$(list_devices | wc -w)"
  [ "$n" -ge 1 ] && [ "$n" -eq "$prev" ] && break
  prev="$n"; sleep 1
done

DEVICES="$(list_devices)"
COUNT="$(echo "$DEVICES" | wc -w)"
echo "Found ${COUNT} instance-store NVMe device(s): ${DEVICES}"
[ "$COUNT" -ge 1 ] || { echo "ERROR: no instance-store NVMe devices found." >&2; exit 1; }

mkdir -p "$MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT"; then
  echo "${MOUNT_POINT} already mounted — leaving it as is."
else
  if [ "$COUNT" -eq 1 ]; then
    TARGET="$DEVICES"
  else
    echo "Creating RAID-0 /dev/md0 over ${COUNT} devices..."
    # shellcheck disable=SC2086  # word-splitting $DEVICES into args is intentional
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices="$COUNT" $DEVICES --run
    TARGET="/dev/md0"
  fi

  mkfs.xfs -f "$TARGET"

  # Persist the array so it reassembles on reboot.
  mkdir -p /etc/mdadm
  mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf
  update-initramfs -u || true

  # Persist the mount by UUID (stable across device renaming).
  UUID="$(blkid -s UUID -o value "$TARGET")"
  grep -q "$UUID" /etc/fstab 2>/dev/null \
    || echo "UUID=${UUID} ${MOUNT_POINT} xfs defaults,noatime,inode64,nofail 0 0" >> /etc/fstab

  mount "$MOUNT_POINT"
fi

chmod 777 "$MOUNT_POINT"
chown "${OWNER}:${OWNER}" "$MOUNT_POINT" 2>/dev/null || true

echo "Mounted RAID-0 (${COUNT} device(s)) at ${MOUNT_POINT}:"
df -h "$MOUNT_POINT"
cat /proc/mdstat 2>/dev/null || true
echo
echo "Next:  export DATA_DIR=${MOUNT_POINT}   then run ../run_all.sh"
