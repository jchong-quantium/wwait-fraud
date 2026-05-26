#!/usr/bin/env bash
# Upload SQL pipeline files to Cloud Storage.
# Run this whenever SQL files in sql/pipeline/ are updated.
#
# Usage:
#   bash scripts/deploy_sql.sh

set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in .env}"
: "${GCS_BUCKET:?GCS_BUCKET must be set in .env}"

SQL_DIR="$(dirname "$0")/../sql/pipeline"

# Upload
echo "Uploading SQL pipeline files to gs://$GCS_BUCKET/sql/pipeline/"
gsutil cp "$SQL_DIR"/*.sql "gs://$GCS_BUCKET/sql/pipeline/"

echo ""
echo "Done. Files in GCS:"
gsutil ls "gs://$GCS_BUCKET/sql/pipeline/"
