"""
BigQuery connectivity test.

Runs a lightweight SELECT 1 LIMIT 1 against each source table to confirm
read access before building the pipeline. Tables that are known to be
pending access are flagged so a failure there is expected, not a surprise.

Usage:
    python3 test/test_bigquery.py

Authentication:
    Uses Application Default Credentials (ADC) or GOOGLE_APPLICATION_CREDENTIALS
    env var. No credentials are hardcoded.
"""

import os
import sys

from dotenv import load_dotenv  # type: ignore
from google.api_core.exceptions import Forbidden, NotFound  # type: ignore
from google.cloud import bigquery

# Load env vars from .env
load_dotenv()

GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
BQ_DATASET = os.environ.get("BQ_DATASET")

if not GCP_PROJECT_ID or not BQ_DATASET:
    sys.exit("Missing GCP_PROJECT_ID or BQ_DATASET in .env")

# Tables to test
# pending_access=True means we expect this to fail until access is granted.
TABLES = [
    # GNFR published datasets
    {
        "label": "Ariba PO line level",
        "table": "gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_PO_Linelevel_v",
        "pending_access": False,
    },
    {
        "label": "Ariba PO and invoices",
        "table": "gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_POandInvoices_v",
        "pending_access": False,
    },
    {
        "label": "Ariba approvals",
        "table": "gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_Approvals_v",
        "pending_access": False,
    },
    {
        "label": "GNFR spend base table",
        "table": "gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v",
        "pending_access": False,
    },
    # Source: master data
    {
        "label": "Vendor master (dim_vendor_v)",
        "table": "gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v",
        "pending_access": False,
    },
    # Source: purchasing
    {
        "label": "SAP document schedule lines",
        "table": "gcp-wow-ent-im-tbl-prod.adp_dm_purchasing_view.document_schedule_lines_v",
        "pending_access": False,
    },
    # Source: financial data
    {
        "label": "SAP accounting doc (bkpf_bseg)",
        "table": "gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v",
        "pending_access": True,
    },
    # Source: DOA limits
    {
        "label": "DOA limits",
        "table": "gcp-wow-risk-de-data-prod.audit_group_enablement.doa",
        "pending_access": True,
    },
    # Target: fraud dataset (write access check)
    {
        "label": f"Target fraud dataset ({GCP_PROJECT_ID}.{BQ_DATASET})",
        "table": f"{GCP_PROJECT_ID}.{BQ_DATASET}.base_transaction",
        "pending_access": False,
    },
    {
        "label": f"Target fraud dataset ({GCP_PROJECT_ID}.{BQ_DATASET})",
        "table": f"{GCP_PROJECT_ID}.{BQ_DATASET}.vendor_attributes",
        "pending_access": False,
    },
    {
        "label": f"Target fraud dataset ({GCP_PROJECT_ID}.{BQ_DATASET})",
        "table": f"{GCP_PROJECT_ID}.{BQ_DATASET}.vendor_features",
        "pending_access": False,
    },
]


def check_table(client: bigquery.Client, table: str) -> tuple[bool, str]:
    """Run a zero-cost query to confirm read access to a table."""
    query = f"SELECT 1 FROM `{table}` LIMIT 1"  # nosec — no user input in query
    try:
        client.query(query).result()
        return True, "ok"
    except Forbidden as e:
        return False, f"FORBIDDEN — {e.message}"
    except NotFound as e:
        return False, f"NOT FOUND — {e.message}"
    except Exception as e:
        return False, str(e)


def main() -> None:
    # Credentials sourced from ADC or GOOGLE_APPLICATION_CREDENTIALS env var
    client = bigquery.Client(project=GCP_PROJECT_ID)

    print(f"{'Status':<10} {'Table'}")

    passed, failed, skipped = 0, 0, 0

    for entry in TABLES:
        success, message = check_table(client, entry["table"])

        if success:
            status = "✅ PASS"
            passed += 1
        elif entry["pending_access"]:
            status = "⏳ PENDING"
            skipped += 1
        else:
            status = "❌ FAIL"
            failed += 1

        print(f"{status:<10} {entry['label']}")
        if not success:
            print(f"           {message}")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
