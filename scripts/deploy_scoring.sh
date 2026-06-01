#!/usr/bin/env bash
# Deploy the transaction scorer as a Cloud Run Job.
#
# Cloud Run Job runs to completion and exits — no persistent HTTP service.
# Trigger a run manually with:
#   gcloud run jobs execute fraud-transaction-scorer --region $GCP_LOCATION
#
# Usage:
#   chmod +x scripts/deploy_scoring.sh
#   ./scripts/deploy_scoring.sh

set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in .env}"
: "${GCP_LOCATION:?GCP_LOCATION must be set in .env}"
: "${BQ_DATASET:?BQ_DATASET must be set in .env}"

JOB_NAME="fraud-transaction-scorer"
IMAGE="$GCP_LOCATION-docker.pkg.dev/$GCP_PROJECT_ID/$JOB_NAME/$JOB_NAME"
SCORING_DIR="$(dirname "$0")/../scoring"

# Create Artifact Registry repository if it doesn't exist
if ! gcloud artifacts repositories describe "$JOB_NAME" \
     --location "$GCP_LOCATION" --project "$GCP_PROJECT_ID" > /dev/null 2>&1; then
  echo "Creating Artifact Registry repository: $JOB_NAME"
  gcloud artifacts repositories create "$JOB_NAME" \
    --repository-format docker \
    --location "$GCP_LOCATION" \
    --project "$GCP_PROJECT_ID"
fi

# Build and push image
echo "Building and pushing image: $IMAGE"
gcloud builds submit "$SCORING_DIR" \
  --tag "$IMAGE" \
  --project "$GCP_PROJECT_ID"

# Create or update the Cloud Run Job
if gcloud run jobs describe "$JOB_NAME" \
   --region "$GCP_LOCATION" --project "$GCP_PROJECT_ID" > /dev/null 2>&1; then
  echo "Updating Cloud Run Job: $JOB_NAME"
  gcloud run jobs update "$JOB_NAME" \
    --image "$IMAGE" \
    --region "$GCP_LOCATION" \
    --service-account "wwait-fraud@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
    --set-env-vars "GCP_PROJECT_ID=$GCP_PROJECT_ID,BQ_DATASET=$BQ_DATASET" \
    --memory 4Gi \
    --cpu 2 \
    --task-timeout 3600 \
    --project "$GCP_PROJECT_ID"
else
  echo "Creating Cloud Run Job: $JOB_NAME"
  gcloud run jobs create "$JOB_NAME" \
    --image "$IMAGE" \
    --region "$GCP_LOCATION" \
    --service-account "wwait-fraud@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
    --set-env-vars "GCP_PROJECT_ID=$GCP_PROJECT_ID,BQ_DATASET=$BQ_DATASET" \
    --memory 4Gi \
    --cpu 2 \
    --task-timeout 3600 \
    --project "$GCP_PROJECT_ID"
fi

echo ""
echo "Deployed: $JOB_NAME"
echo "To run:   gcloud run jobs execute $JOB_NAME --region $GCP_LOCATION --project $GCP_PROJECT_ID"