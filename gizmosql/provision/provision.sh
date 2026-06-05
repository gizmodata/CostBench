#!/usr/bin/env bash
# Launch an EC2 instance for the GizmoSQL CostBench runs, with mount_nvme.sh wired
# in as user-data so the local NVMe is RAID-0'd and mounted at /mnt/nvme at boot.
#
#   ./provision.sh
#
# Config is read from ./.env (gitignored) — see .env.example. At minimum set
# AWS credentials (or an AWS_PROFILE) and KEY_NAME. Everything is overridable via
# environment variables:
#
#   KEY_NAME            (required) existing EC2 SSH key pair name, for ssh access
#   INSTANCE_TYPE       default i8ge.24xlarge
#   REGION              default $AWS_REGION, else us-east-1 (matches the pricing files)
#   SECURITY_GROUP_IDS  use an existing SG; if unset, a 'gizmosql-costbench-ssh' SG
#                       is found-or-created in the default VPC allowing SSH from your IP
#   SUBNET_ID           default: the account's default subnet (auto-assigns public IP)
#   ROOT_GB             root EBS gp3 size in GiB, default 100
#   AMI                 default: latest Ubuntu 24.04 amd64 (resolved via SSM)
#   NAME                instance Name tag, default gizmosql-costbench
#   SPOT=1              request a spot instance (cheaper, but an interruption wipes
#                       the ephemeral NVMe AND the in-progress run -- risky for 100B)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load local config (AWS creds/profile, KEY_NAME, etc.). .env is gitignored.
[ -f "${SCRIPT_DIR}/.env" ] && . "${SCRIPT_DIR}/.env"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found." >&2; exit 1; }
KEY_NAME="${KEY_NAME:?set KEY_NAME (existing EC2 key pair) in .env or the environment}"
INSTANCE_TYPE="${INSTANCE_TYPE:-i8ge.24xlarge}"
REGION="${REGION:-${AWS_REGION:-us-east-1}}"
ROOT_GB="${ROOT_GB:-100}"
NAME="${NAME:-gizmosql-costbench}"

echo "Region: ${REGION}   Instance: ${INSTANCE_TYPE}   Key: ${KEY_NAME}"
[ "$REGION" = "us-east-1" ] || echo "NOTE: pricing files here are us-east-1; verify ${INSTANCE_TYPE} pricing for ${REGION} (or update pricings/aws.${INSTANCE_TYPE}.json)." >&2

# Resolve the AMI (latest Ubuntu 24.04 amd64) unless one was supplied.
AMI="${AMI:-$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)}"
echo "AMI: ${AMI}"

# Security group: use the one provided, else find-or-create one that allows SSH
# from your current public IP in the default VPC.
if [ -z "${SECURITY_GROUP_IDS:-}" ]; then
  SG_NAME="gizmosql-costbench-ssh"
  VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
            --query 'Vpcs[0].VpcId' --output text)"
  [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ] \
    || { echo "ERROR: no default VPC in ${REGION}; set SECURITY_GROUP_IDS=sg-..." >&2; exit 1; }
  SECURITY_GROUP_IDS="$(aws ec2 describe-security-groups --region "$REGION" \
      --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
  if [ "$SECURITY_GROUP_IDS" = "None" ] || [ -z "$SECURITY_GROUP_IDS" ]; then
    SECURITY_GROUP_IDS="$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$SG_NAME" --description "GizmoSQL CostBench SSH" \
        --vpc-id "$VPC_ID" --query GroupId --output text)"
    echo "Created security group ${SECURITY_GROUP_IDS} (${SG_NAME})"
  fi
  MYIP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  aws ec2 authorize-security-group-ingress --region "$REGION" \
      --group-id "$SECURITY_GROUP_IDS" --protocol tcp --port 22 --cidr "${MYIP}/32" \
      >/dev/null 2>&1 || true   # ignore "already exists"
  echo "Security group: ${SECURITY_GROUP_IDS} (SSH from ${MYIP}/32)"
fi

# Spot is opt-in (no spaces in the value, so unquoted word-splitting is bash-3.2 safe).
SPOT_OPT=""
[ "${SPOT:-0}" = "1" ] && SPOT_OPT="--instance-market-options MarketType=spot"

IID="$(aws ec2 run-instances --region "$REGION" \
  --instance-type "$INSTANCE_TYPE" \
  --image-id "$AMI" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP_IDS" \
  ${SUBNET_ID:+--subnet-id "$SUBNET_ID"} \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data "file://${SCRIPT_DIR}/mount_nvme.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
  ${SPOT_OPT} \
  --count 1 --query 'Instances[0].InstanceId' --output text)"
echo "Launched instance: ${IID}"

echo "Waiting for it to reach 'running'..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
DNS="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
       --query 'Reservations[0].Instances[0].PublicDnsName' --output text)"

cat <<EOF

  Instance:    ${IID}   (${INSTANCE_TYPE}, ${REGION})
  Public DNS:  ${DNS}

  user-data (mount_nvme.sh) is building the NVMe RAID-0 at /mnt/nvme now.
  Give it ~1-2 min, then:

    ssh ubuntu@${DNS}
      df -h /mnt/nvme && cat /proc/mdstat          # confirm the ~60 TB RAID-0 mounted
      # clone/scp the CostBench fork's gizmosql/ dir up, then:
      cd gizmosql
      export DATA_DIR=/mnt/nvme
      MACHINE=${INSTANCE_TYPE} MEMORY_GIB=768 INSTALL=1 nohup ./run_all.sh > run_all.log 2>&1 &
      tail -f run_all.log

  Teardown when done:
    REGION=${REGION} ./teardown.sh
EOF
