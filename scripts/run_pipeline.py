"""
run_pipeline.py — Local pipeline runner using personal ADC credentials.

Bridge solution while the Workflows service account is awaiting access to
enterprise source datasets. Uses your personal Google credentials (via ADC)
to run each SQL pipeline step against BigQuery, then triggers the Cloud Run
brief generation service.

Prerequisites:
    gcloud auth application-default login   # authenticate once

Usage:
    python3 scripts/run_pipeline.py            # setup views + pipeline SQL + brief trigger
    python3 scripts/run_pipeline.py --sql-only # setup views + pipeline SQL only

Notes:
    - This script is for development and testing only.
    - Production orchestration uses GCP Workflows (workflows/pipeline.yaml).
    - All config is loaded from .env — no credentials are hardcoded.
    - SQL files are executed in the order defined in SQL_FILES / SETUP_FILES below.
      Update these lists when new pipeline steps are added.
"""

import argparse
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
BQ_DATASET = os.environ.get("BQ_DATASET")
CLOUD_RUN_URL = os.environ.get("CLOUD_RUN_URL")

if not GCP_PROJECT_ID:
    sys.exit("ERROR: GCP_PROJECT_ID must be set in .env")

if not BQ_DATASET:
    sys.exit("ERROR: BQ_DATASET must be set in .env")

# SQL file lists — filenames only, never user-supplied, to prevent path traversal.
# Paths are constructed at runtime from known directories (SQL_DIR / SETUP_DIR).
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL_DIR = REPO_ROOT / "sql" / "pipeline"
SETUP_DIR = REPO_ROOT / "sql" / "setup"

# Setup views — always run first; idempotent (CREATE OR REPLACE VIEW).
# Must be run before pipeline files as pipeline tables depend on these views.
SETUP_FILES = [
    "ariba_po_invoice_vw.sql",
    "base_payment_vw.sql",
    "sap_invoices_vw.sql",
    "sap_po_vw.sql",
]

# Pipeline tables — executed in dependency order on every pipeline run.
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


def run_sql_step(
    client: bigquery.Client, sql_file: str, base_dir: pathlib.Path
) -> None:
    """
    Read a SQL file and submit it as a BigQuery job.
    Blocks until the job completes. Raises on error.

    sql_file is a filename only (no path components) — the full path is
    constructed from the caller-supplied base_dir (always SQL_DIR or SETUP_DIR,
    never user input) to prevent path traversal.
    """
    # Construct path from known directory — never concatenate user input
    sql_path = (base_dir / sql_file).resolve()

    # Verify the resolved path is still within base_dir (defence in depth)
    if not str(sql_path).startswith(str(base_dir)):
        raise ValueError(f"Path traversal detected for: {sql_file}")

    if not sql_path.exists():
        raise FileNotFoundError(f"SQL file not found: {sql_path}")

    sql = _apply_sql_vars(sql_path.read_text(encoding="utf-8"))

    if not sql.strip():
        logger.warning("Skipping %s — file is empty", sql_file)
        return

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


def _run_files(
    client: bigquery.Client,
    files: list[str],
    base_dir: pathlib.Path,
    skip_on_error: bool = False,
) -> None:
    for sql_file in files:
        logger.info("Running: %s", sql_file)
        try:
            run_sql_step(client, sql_file, base_dir)
            logger.info("Done")
        except FileNotFoundError as e:
            logger.error("%s", e)
            sys.exit(1)
        except GoogleCloudError as e:
            if skip_on_error:
                logger.warning("Skipping %s — %s", sql_file, e)
            else:
                logger.error("BigQuery error: %s", e)
                sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description="Fraud pipeline — local runner")
    parser.add_argument(
        "--sql-only",
        action="store_true",
        help="Skip the Cloud Run brief generation trigger after SQL execution.",
    )
    args = parser.parse_args()

    logger.info("=" * 60)
    logger.info("Project:  %s", GCP_PROJECT_ID)
    logger.info("Dataset:  %s", BQ_DATASET)
    logger.info("=" * 60)

    # BigQuery client uses ADC automatically — no credentials passed explicitly
    client = bigquery.Client(project=GCP_PROJECT_ID)

    logger.info("--- Setup views ---")
    _run_files(client, SETUP_FILES, SETUP_DIR, skip_on_error=True)

    logger.info("--- Pipeline tables ---")
    _run_files(client, SQL_FILES, SQL_DIR)

    if args.sql_only:
        logger.info("=" * 60)
        logger.info("Pipeline complete (SQL only)")
        logger.info("=" * 60)
        return

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
