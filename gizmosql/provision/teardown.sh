#!/usr/bin/env bash
# Terminate the GizmoSQL CostBench instance(s) launched by provision.sh.
#
#   ./teardown.sh [INSTANCE_ID]
#
# With no argument, terminates every non-terminated instance tagged
# Name=$NAME (default gizmosql-costbench). Reads ./.env for AWS creds/region.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "${SCRIPT_DIR}/.env" ] && . "${SCRIPT_DIR}/.env"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found." >&2; exit 1; }
REGION="${REGION:-${AWS_REGION:-us-east-1}}"
NAME="${NAME:-gizmosql-costbench}"

if [ "${1:-}" != "" ]; then
  IIDS="$1"
else
  IIDS="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
fi

[ -n "$IIDS" ] || { echo "No instances tagged Name=${NAME} in ${REGION}."; exit 0; }

echo "Terminating in ${REGION}: ${IIDS}"
# shellcheck disable=SC2086  # split multiple instance IDs into args
aws ec2 terminate-instances --region "$REGION" --instance-ids $IIDS \
  --query 'TerminatingInstances[].{id:InstanceId,state:CurrentState.Name}' --output text

echo "Done. (The auto-created 'gizmosql-costbench-ssh' security group is left for reuse;"
echo " delete it manually if you no longer need it.)"
