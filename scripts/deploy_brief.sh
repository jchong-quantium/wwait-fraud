#!/usr/bin/env bash
# Deploy the brief generation service to Cloud Run.
#
# Usage:
#   chmod +x scripts/deploy_brief.sh
#   ./scripts/deploy_brief.sh

set -euo pipefail

# Config 
PROJECT_ID="gcp-wow-groupit-bizwear-dev" # "agentic-platforms-sandbox"
REGION="australia-southeast1"
SERVICE_NAME="fraud-case-brief"
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$SERVICE_NAME/$SERVICE_NAME"
BRIEF_DIR="$(dirname "$0")/../brief"

# Create Artifact Registry repository if it doesn't exist
if ! gcloud artifacts repositories describe "$SERVICE_NAME" \
     --location "$REGION" --project "$PROJECT_ID" > /dev/null 2>&1; then
  echo "Creating Artifact Registry repository: $SERVICE_NAME"
  gcloud artifacts repositories create "$SERVICE_NAME" \
    --repository-format docker \
    --location "$REGION" \
    --project "$PROJECT_ID"
fi

# Build
echo "Building and pushing image: $IMAGE"
gcloud builds submit "$BRIEF_DIR" \
  --tag "$IMAGE" \
  --project "$PROJECT_ID"

# Deploy 
echo "Deploying $SERVICE_NAME to Cloud Run ($REGION)..."
gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --project "$PROJECT_ID"

# Print service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --format "value(status.url)")

echo ""
echo "Deployed: $SERVICE_URL"
echo "Add this to your .env as CLOUD_RUN_URL=$SERVICE_URL"