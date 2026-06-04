"""
run_pipeline.py — Local pipeline runner using personal ADC credentials.

Bridge solution while the Workflows service account is awaiting access to
enterprise source datasets. Uses your personal Google credentials (via ADC)
to run each SQL pipeline step against BigQuery, then generates case briefs
by calling builder.py directly and uploading results to GCS.

Note: brief generation bypasses Cloud Run (main.py) due to OIDC auth constraints
with personal ADC credentials. 

Prerequisites:
    gcloud auth application-default login   # authenticate once

Usage:
    python3 scripts/run_pipeline.py            # setup views + pipeline SQL + briefs
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
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from zoneinfo import ZoneInfo

from dotenv import load_dotenv  # type: ignore
from google.cloud import bigquery, storage
from google.cloud.exceptions import GoogleCloudError  # type: ignore

# Add brief/ to path so builder can be imported directly for local runs
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "brief"))

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
GCS_BUCKET = os.environ.get("GCS_BUCKET")
BRIEF_VENDOR_LIMIT = int(os.environ.get("BRIEF_VENDOR_LIMIT") or "10")
BRIEF_WORKERS = int(os.environ.get("BRIEF_WORKERS") or "3")

MELBOURNE_TZ = ZoneInfo("Australia/Melbourne")

if not GCP_PROJECT_ID:
    sys.exit("ERROR: GCP_PROJECT_ID must be set in .env")

if not BQ_DATASET:
    sys.exit("ERROR: BQ_DATASET must be set in .env")

if not GCS_BUCKET:
    sys.exit("ERROR: GCS_BUCKET must be set in .env")

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

# Pipeline tables — split into pre-scorer and post-scorer groups.
# transaction_scorer.py runs between the two groups and writes transaction_scores.
SQL_FILES_PRE_SCORER = [
    "vendor_attributes.sql",
    "employee_attributes.sql",
    "base_transaction.sql",
    "vendor_features.sql",
    "model_input.sql",         # pre-engineered feature matrix for IsoForest
    "transaction_scores.sql",  # schema stub — populated by scorer
]

SQL_FILES_POST_SCORER = [
    "vendor_scores.sql",       # reads from transaction_scores
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


def _run_scorer() -> None:
    """Run the transaction scorer inline using the local Python environment.

    In production, this is a Cloud Run Job triggered by GCP Workflows.
    Locally, we run it directly for development convenience.
    scorer path is constructed from a known constant — not user-supplied (CWE-22).
    """
    import subprocess  # noqa: PLC0415 — deferred import, only used here

    scorer_path = (REPO_ROOT / "scoring" / "transaction_scorer.py").resolve()
    if not str(scorer_path).startswith(str(REPO_ROOT)):
        raise ValueError("Path traversal detected for scorer path")

    logger.info("Running transaction scorer: %s", scorer_path)
    result = subprocess.run(
        [sys.executable, str(scorer_path)],
        check=False,
    )
    if result.returncode != 0:
        logger.error("Transaction scorer exited with code %d", result.returncode)
        sys.exit(result.returncode)
    logger.info("Transaction scorer complete")


def _process_vendor(
    vendor_id: str,
    client: bigquery.Client,
    bucket: storage.Bucket,
    run_ts: str,
) -> str:
    """Build and upload a case brief for a single vendor."""
    from builder import build_case_brief, generate_case_brief_html  # type: ignore

    logger.info("Generating brief: %s", vendor_id)
    brief = build_case_brief(vendor_id, client=client)
    brief["generated_at"] = datetime.now(tz=MELBOURNE_TZ).strftime("%-d %B %Y")
    html = generate_case_brief_html(brief)
    blob_name = f"briefs/{run_ts}/case_brief_{vendor_id}.html"
    bucket.blob(blob_name).upload_from_string(html, content_type="text/html; charset=utf-8")
    return blob_name


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
        help="Skip brief generation after SQL execution.",
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

    logger.info("--- Pipeline tables (pre-scorer) ---")
    _run_files(client, SQL_FILES_PRE_SCORER, SQL_DIR)

    logger.info("--- Transaction scorer ---")
    if not args.sql_only:
        _run_scorer()

    logger.info("--- Pipeline tables (post-scorer) ---")
    _run_files(client, SQL_FILES_POST_SCORER, SQL_DIR)

    if args.sql_only:
        logger.info("=" * 60)
        logger.info("Pipeline complete (SQL only)")
        logger.info("=" * 60)
        return

    # Brief generation — calls builder directly; see module docstring for why
    from builder import select_top_vendors  # type: ignore

    logger.info("Fetching top %d vendors by anomaly score...", BRIEF_VENDOR_LIMIT)
    vendors = select_top_vendors(BRIEF_VENDOR_LIMIT, client)

    if not vendors:
        logger.warning("No vendors found in vendor_scores — skipping brief generation")
    else:
        gcs_client = storage.Client(project=GCP_PROJECT_ID)
        bucket = gcs_client.bucket(GCS_BUCKET)
        run_ts = datetime.now(tz=MELBOURNE_TZ).strftime("%Y%m%dT%H%M%S")

        failed = 0
        with ThreadPoolExecutor(max_workers=BRIEF_WORKERS) as executor:
            futures = {
                executor.submit(_process_vendor, v, client, bucket, run_ts): v
                for v in vendors
            }
            for future in as_completed(futures):
                vendor_id = futures[future]
                try:
                    blob_name = future.result()
                    logger.info("  Uploaded: gs://%s/%s", GCS_BUCKET, blob_name)
                except Exception as e:
                    logger.error("  Failed for %s: %s", vendor_id, e)
                    failed += 1
        if failed:
            logger.warning("%d brief(s) failed", failed)

    logger.info("=" * 60)
    logger.info("Pipeline complete")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()