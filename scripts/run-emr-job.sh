#!/usr/bin/env bash
# Launch a TRANSIENT EMR cluster, run the anomaly job, and let it terminate.
#
# --auto-terminate is the whole point. The cluster shuts itself down when the
# last step finishes, whether the step succeeded or failed. A cluster left
# running is the single most expensive mistake available in this project:
# roughly $0.24/hour per m5.xlarge including the EMR uplift, billed until
# someone notices.
#
# Everything durable (roles, instance profile, security groups) is Terraform's.
# This script only creates the ephemeral thing.
#
# Usage:
#   ./scripts/run-emr-job.sh              # launch, wait, report
#   ./scripts/run-emr-job.sh --no-wait    # launch and return immediately

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$REPO_ROOT/envs/dev"

WAIT=1
[[ "${1:-}" == "--no-wait" ]] && WAIT=0

tf() { terraform -chdir="$ENV_DIR" output -raw "$1"; }

echo "Reading Terraform outputs..."
RAW_URI="$(tf telemetry_s3_uri)"
CURATED_BUCKET="$(tf curated_bucket_name)"
SERVICE_ROLE="$(tf emr_service_role_name)"
INSTANCE_PROFILE="$(tf emr_instance_profile_name)"
MASTER_SG="$(tf emr_master_security_group_id)"
CORE_SG="$(tf emr_core_security_group_id)"
SERVICE_SG="$(tf emr_service_access_security_group_id)"
SUBNET="$(terraform -chdir="$ENV_DIR" output -json private_subnet_ids | python3 -c 'import sys,json;print(json.load(sys.stdin)[0])')"

CURATED_URI="s3://${CURATED_BUCKET}/anomalies/"
LOG_URI="s3://${CURATED_BUCKET}/emr-logs/"
JOB_URI="s3://${CURATED_BUCKET}/jobs/anomaly_detection.py"

echo "Uploading the job to S3..."
aws s3 cp "$REPO_ROOT/jobs/anomaly_detection.py" "$JOB_URI" --only-show-errors

# The cluster sits in a PRIVATE subnet, which is why a service access security
# group is required. Its S3 traffic goes through the gateway endpoint added in
# Phase 9, so the bytes it reads and writes are not billed as NAT data --
# but the nodes still need the NAT up to reach the EMR service endpoints.
echo "Launching transient cluster..."
CLUSTER_ID=$(aws emr create-cluster \
  --name "yefter-dev-anomaly-$(date +%Y%m%d-%H%M%S)" \
  --release-label "${EMR_RELEASE:-emr-7.13.0}" \
  --applications Name=Spark \
  --log-uri "$LOG_URI" \
  --service-role "$SERVICE_ROLE" \
  --auto-terminate \
  --ec2-attributes "{
      \"InstanceProfile\":\"$INSTANCE_PROFILE\",
      \"SubnetId\":\"$SUBNET\",
      \"EmrManagedMasterSecurityGroup\":\"$MASTER_SG\",
      \"EmrManagedSlaveSecurityGroup\":\"$CORE_SG\",
      \"ServiceAccessSecurityGroup\":\"$SERVICE_SG\"
    }" \
  --instance-groups "[
      {\"InstanceGroupType\":\"MASTER\",\"InstanceCount\":1,\"InstanceType\":\"${EMR_INSTANCE_TYPE:-m5.xlarge}\"},
      {\"InstanceGroupType\":\"CORE\",\"InstanceCount\":1,\"InstanceType\":\"${EMR_INSTANCE_TYPE:-m5.xlarge}\"}
    ]" \
  --steps "[{
      \"Type\":\"CUSTOM_JAR\",
      \"Name\":\"anomaly-detection\",
      \"Jar\":\"command-runner.jar\",
      \"ActionOnFailure\":\"TERMINATE_CLUSTER\",
      \"Args\":[
        \"spark-submit\",\"--deploy-mode\",\"cluster\",
        \"$JOB_URI\",
        \"--raw-uri\",\"$RAW_URI\",
        \"--curated-uri\",\"$CURATED_URI\"
      ]
    }]" \
  --tags "for-use-with-amazon-emr-managed-policies=true" "Project=yefter-iia-platform" "Environment=dev" \
  --query 'ClusterId' --output text)

echo "Cluster: $CLUSTER_ID"
echo "Console: https://console.aws.amazon.com/emr/home#/clusterDetails/$CLUSTER_ID"

if [[ "$WAIT" -eq 0 ]]; then
  echo
  echo "Not waiting. It will terminate itself when the step finishes."
  echo "Check with: aws emr describe-cluster --cluster-id $CLUSTER_ID --query 'Cluster.Status.State'"
  exit 0
fi

echo
echo "Waiting. Expect ~7 minutes of bootstrap before the job even starts."

LAST=""
while true; do
  STATE=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --query 'Cluster.Status.State' --output text)
  if [[ "$STATE" != "$LAST" ]]; then
    echo "  [$(date +%H:%M:%S)] $STATE"
    LAST="$STATE"
  fi
  case "$STATE" in
    TERMINATED|TERMINATED_WITH_ERRORS) break ;;
  esac
  sleep 20
done

echo
aws emr describe-cluster --cluster-id "$CLUSTER_ID" \
  --query 'Cluster.Status.StateChangeReason' --output json

STEP_STATE=$(aws emr list-steps --cluster-id "$CLUSTER_ID" --query 'Steps[0].Status.State' --output text)
echo "Step: $STEP_STATE"

if [[ "$STEP_STATE" != "COMPLETED" ]]; then
  echo
  echo "The step did not complete. Driver logs are under:"
  echo "  ${LOG_URI}${CLUSTER_ID}/"
  exit 1
fi

echo
echo "Done. Output:"
aws s3 ls "$CURATED_URI" --recursive --human-readable | head -20
