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
KEY_NAME="${KEY_NAME:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-i8ge.24xlarge}"
REGION="${REGION:-${AWS_REGION:-us-east-1}}"
ROOT_GB="${ROOT_GB:-100}"
NAME="${NAME:-gizmosql-costbench}"

echo "Region: ${REGION}   Instance: ${INSTANCE_TYPE}"
[ "$REGION" = "us-east-1" ] || echo "NOTE: pricing files here are us-east-1; verify ${INSTANCE_TYPE} pricing for ${REGION} (or update pricings/aws.${INSTANCE_TYPE}.json)." >&2

# SSH key pair: use KEY_NAME if passed, otherwise create one and save the .pem
# locally (gitignored). AWS returns the private key only at creation time, so if
# the named key already exists in AWS but we have no local .pem, we recreate it.
PEM=""
if [ -n "$KEY_NAME" ]; then
  echo "Key pair: ${KEY_NAME} (existing)"
else
  KEY_NAME="gizmosql-costbench-key"
  PEM="${SCRIPT_DIR}/${KEY_NAME}.pem"
  key_exists="$(aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" \
                --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo None)"
  if [ "$key_exists" = "$KEY_NAME" ] && [ -f "$PEM" ]; then
    echo "Key pair: ${KEY_NAME} (reusing ${PEM})"
  else
    if [ "$key_exists" = "$KEY_NAME" ]; then
      aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" >/dev/null 2>&1 || true
    fi
    ( umask 177; aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
        --query KeyMaterial --output text > "$PEM" )
    chmod 400 "$PEM"
    echo "Key pair: ${KEY_NAME} (created; private key saved to ${PEM})"
  fi
fi

# Resolve the AMI unless one was supplied: detect the instance type's CPU
# architecture (arm64 for Graviton like i8ge, else x86_64) and pick the matching
# latest Ubuntu 24.04 image, so the AMI arch always matches the instance.
if [ -z "${AMI:-}" ]; then
  ARCH="$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$INSTANCE_TYPE" \
          --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)"
  case "$ARCH" in
    arm64)  AMI_ARCH=arm64 ;;
    x86_64) AMI_ARCH=amd64 ;;
    *) echo "ERROR: could not determine architecture for ${INSTANCE_TYPE} (got '${ARCH}')." >&2; exit 1 ;;
  esac
  AMI="$(aws ssm get-parameter --region "$REGION" \
    --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/${AMI_ARCH}/hvm/ebs-gp3/ami-id" \
    --query Parameter.Value --output text)"
  echo "Architecture: ${ARCH} (Ubuntu ${AMI_ARCH})   AMI: ${AMI}"
else
  echo "AMI: ${AMI} (provided)"
fi

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

if [ -n "$PEM" ]; then SSH_CMD="ssh -i ${PEM} ubuntu@${DNS}"
else SSH_CMD="ssh -i <your-key>.pem ubuntu@${DNS}"; fi

# Print the connection instructions AND save them (overwrite) to a gitignored
# file, so you can always recover the ssh / run / teardown commands later.
DETAILS="${SCRIPT_DIR}/instance_details.txt"
cat <<EOF | tee "$DETAILS"

  Instance:    ${IID}   (${INSTANCE_TYPE}, ${REGION})
  Public DNS:  ${DNS}

  user-data (mount_nvme.sh) is building the NVMe RAID-0 at /mnt/nvme now.
  Give it ~1-2 min, then:

    ${SSH_CMD}
      df -h /mnt/nvme && cat /proc/mdstat          # confirm the ~60 TB RAID-0 mounted
      # clone/scp the CostBench fork's gizmosql/ dir up, then:
      cd gizmosql
      export DATA_DIR=/mnt/nvme
      MACHINE=${INSTANCE_TYPE} MEMORY_GIB=768 INSTALL=1 nohup ./run_all.sh > run_all.log 2>&1 &
      tail -f run_all.log

  Teardown when done:
    REGION=${REGION} ./teardown.sh
EOF
echo "(connection details saved to ${DETAILS})"
