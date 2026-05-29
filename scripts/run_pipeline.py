"""
run_pipeline.py — Local pipeline runner using personal ADC credentials.

Bridge solution while the Workflows service account is awaiting access to
enterprise source datasets. Uses your personal Google credentials (via ADC)
to run each SQL pipeline step against BigQuery, then triggers the Cloud Run
brief generation service.

Prerequisites:
    gcloud auth application-default login   # authenticate once

Usage:
    python3 scripts/run_pipeline.py

Notes:
    - This script is for development and testing only.
    - Production orchestration uses GCP Workflows (workflows/pipeline.yaml).
    - All config is loaded from .env — no credentials are hardcoded.
    - SQL files are executed in the order defined in SQL_FILES below.
      Update this list when new pipeline steps are added.
"""

import logging
import os
import pathlib
import sys

import requests  # type: ignore
from dotenv import load_dotenv  # type: ignore
from google.auth.transport.requests import Request  # type: ignore
from google.cloud import bigquery
from google.cloud.exceptions import GoogleCloudError  # type: ignore
from google.oauth2 import id_token  # type: ignore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

# Config
load_dotenv()

GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
GCP_LOCATION = os.environ.get("GCP_LOCATION")
BQ_DATASET = os.environ.get("BQ_DATASET")
CLOUD_RUN_URL = os.environ.get("CLOUD_RUN_URL")

if not GCP_PROJECT_ID or not GCP_LOCATION:
    sys.exit("ERROR: GCP_PROJECT_ID and GCP_LOCATION must be set in .env")

if not BQ_DATASET:
    sys.exit("ERROR: BQ_DATASET must be set in .env")

# SQL pipeline files — executed in this order
# Add new pipeline steps here as they are built.
# Paths are relative to sql/pipeline/ and are hardcoded (not user-supplied)
# to prevent path traversal.
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL_DIR = REPO_ROOT / "sql" / "pipeline"

SQL_FILES = [
    "vendor_attributes.sql",
    "employee_attributes.sql",
    "base_transaction.sql",
    "vendor_features.sql",
]


def _apply_sql_vars(sql: str) -> str:
    """Replace ${VAR} placeholders in SQL with validated env var values.

    Values come from environment variables validated at startup — never user input,
    so there is no injection risk here.
    """
    substitutions = {
        "${GCP_PROJECT_ID}": GCP_PROJECT_ID,
        "${BQ_DATASET}": BQ_DATASET,
    }
    for placeholder, value in substitutions.items():
        sql = sql.replace(placeholder, value)
    return sql


def run_sql_step(client: bigquery.Client, sql_file: str) -> None:
    """
    Read a SQL file and submit it as a BigQuery job.
    Blocks until the job completes. Raises on error.

    sql_file is a filename only (no path components) — the full path is
    constructed from the known SQL_DIR to prevent path traversal.
    """
    # Construct path from known directory — never concatenate user input
    sql_path = (SQL_DIR / sql_file).resolve()

    # Verify the resolved path is still within SQL_DIR (defence in depth)
    if not str(sql_path).startswith(str(SQL_DIR)):
        raise ValueError(f"Path traversal detected for: {sql_file}")

    if not sql_path.exists():
        raise FileNotFoundError(f"SQL file not found: {sql_path}")

    sql = _apply_sql_vars(sql_path.read_text(encoding="utf-8"))

    job_config = bigquery.QueryJobConfig()
    job = client.query(sql, job_config=job_config)

    logger.info("  Job ID: %s", job.job_id)
    job.result()  # blocks until done, raises google.cloud.exceptions.GoogleCloudError on failure

    logger.info("  Rows affected: %s", job.num_dml_affected_rows)


def trigger_brief_service(vendor_id: str) -> dict:
    """
    Call the Cloud Run brief generation service with OIDC authentication.
    Uses ADC to fetch an identity token — no credentials hardcoded.
    """
    if not CLOUD_RUN_URL:
        logger.warning("CLOUD_RUN_URL not set in .env — skipping brief generation")
        return {}

    generate_url = f"{CLOUD_RUN_URL.rstrip('/')}/generate"

    # Fetch OIDC identity token using ADC — required for private Cloud Run services
    auth_req = Request()
    token = id_token.fetch_id_token(auth_req, CLOUD_RUN_URL)

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    response = requests.post(
        generate_url,
        headers=headers,
        json={"vendor_id": vendor_id},
        timeout=300,  # 5 min timeout — brief generation may take time
    )
    response.raise_for_status()
    return response.json()


def main() -> None:
    logger.info("=" * 60)
    logger.info("Fraud pipeline — local run")
    logger.info("Project:  %s", GCP_PROJECT_ID)
    logger.info("Location: %s", GCP_LOCATION)
    logger.info("=" * 60)

    # BigQuery client uses ADC automatically — no credentials passed explicitly
    client = bigquery.Client(project=GCP_PROJECT_ID)

    # Run SQL pipeline steps in order
    for sql_file in SQL_FILES:
        logger.info("Running: %s", sql_file)
        try:
            run_sql_step(client, sql_file)
            logger.info("Done")
        except FileNotFoundError as e:
            logger.error("%s", e)
            sys.exit(1)
        except GoogleCloudError as e:
            logger.error("BigQuery error: %s", e)
            sys.exit(1)

    # Trigger Cloud Run brief generation
    # TODO: replace test vendor with loop over case_brief_inputs table rows
    logger.info("Triggering brief generation service...")
    try:
        result = trigger_brief_service(vendor_id="test-vendor-001")
        logger.info("Response: %s", result)
    except requests.RequestException as e:
        logger.error("Cloud Run error: %s", e)
        sys.exit(1)

    logger.info("=" * 60)
    logger.info("Pipeline complete")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()
