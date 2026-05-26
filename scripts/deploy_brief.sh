#!/usr/bin/env bash
# Deploy the brief generation service to Cloud Run.
#
# Usage:
#   chmod +x scripts/deploy_brief.sh
#   ./scripts/deploy_brief.sh

set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in .env}"
: "${GCP_LOCATION:?GCP_LOCATION must be set in .env}"

SERVICE_NAME="fraud-case-brief"
IMAGE="$GCP_LOCATION-docker.pkg.dev/$GCP_PROJECT_ID/$SERVICE_NAME/$SERVICE_NAME"
BRIEF_DIR="$(dirname "$0")/../brief"

# Create Artifact Registry repository if it doesn't exist
if ! gcloud artifacts repositories describe "$SERVICE_NAME" \
     --location "$GCP_LOCATION" --project "$GCP_PROJECT_ID" > /dev/null 2>&1; then
  echo "Creating Artifact Registry repository: $SERVICE_NAME"
  gcloud artifacts repositories create "$SERVICE_NAME" \
    --repository-format docker \
    --location "$GCP_LOCATION" \
    --project "$GCP_PROJECT_ID"
fi

# Build
echo "Building and pushing image: $IMAGE"
gcloud builds submit "$BRIEF_DIR" \
  --tag "$IMAGE" \
  --project "$GCP_PROJECT_ID"

# Deploy 
echo "Deploying $SERVICE_NAME to Cloud Run ($GCP_LOCATION)..."
gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE" \
  --region "$GCP_LOCATION" \
  --no-allow-unauthenticated \
  --project "$GCP_PROJECT_ID"

# Print service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region "$GCP_LOCATION" \
  --project "$GCP_PROJECT_ID" \
  --format "value(status.url)")

echo ""
echo "Deployed: $SERVICE_URL"
echo "Add this to your .env as CLOUD_RUN_URL=$SERVICE_URL"