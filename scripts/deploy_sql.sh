#!/usr/bin/env bash
# Upload SQL pipeline files to Cloud Storage.
# Run this whenever SQL files in sql/pipeline/ are updated.
#
# Usage:
#   bash scripts/deploy_sql.sh

set -euo pipefail

# Config 
PROJECT_ID="gcp-wow-groupit-bizwear-dev"
BUCKET="fraud-pipeline-dev"
SQL_DIR="$(dirname "$0")/../sql/pipeline"

# Upload
echo "Uploading SQL pipeline files to gs://$BUCKET/sql/pipeline/"
gsutil cp "$SQL_DIR"/*.sql "gs://$BUCKET/sql/pipeline/"

echo ""
echo "Done. Files in GCS:"
gsutil ls "gs://$BUCKET/sql/pipeline/"