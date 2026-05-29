#!/usr/bin/env bash
# Deploy the fraud pipeline workflow to GCP Workflows.
#
# Usage:
#   bash scripts/deploy_workflow.sh

set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in .env}"
: "${GCP_LOCATION:?GCP_LOCATION must be set in .env}"

WORKFLOW_NAME="wwait-fraud-pipeline"
WORKFLOW_FILE="$(dirname "$0")/../workflows/pipeline.yaml"

# Deploy
echo "Deploying workflow: $WORKFLOW_NAME"
gcloud workflows deploy "$WORKFLOW_NAME" \
  --source "$WORKFLOW_FILE" \
  --location "$GCP_LOCATION" \
  --service-account "wwait-fraud@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
  --project "$GCP_PROJECT_ID"

echo ""
echo "Deployed: $WORKFLOW_NAME"
echo "To execute, run:"
echo "  gcloud workflows run $WORKFLOW_NAME --location $GCP_LOCATION --project $GCP_PROJECT_ID --data '{\"project_id\": \"$GCP_PROJECT_ID\"}'"
