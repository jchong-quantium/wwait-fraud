#!/usr/bin/env bash
# Deploy the fraud pipeline workflow to GCP Workflows.
#
# Usage:
#   bash scripts/deploy_workflow.sh

set -euo pipefail

# Config
PROJECT_ID="gcp-wow-groupit-bizwear-dev" # "agentic-platforms-sandbox"
REGION="australia-southeast1"
WORKFLOW_NAME="fraud-pipeline"
WORKFLOW_FILE="$(dirname "$0")/../workflows/pipeline.yaml"

# Deploy
echo "Deploying workflow: $WORKFLOW_NAME"
gcloud workflows deploy "$WORKFLOW_NAME" \
  --source "$WORKFLOW_FILE" \
  --location "$REGION" \
  --project "$PROJECT_ID"

echo ""
echo "Deployed: $WORKFLOW_NAME"
echo "To execute, run:"
echo "  gcloud workflows run $WORKFLOW_NAME --location $REGION --project $PROJECT_ID --data '{\"project_id\": \"$PROJECT_ID\"}'"