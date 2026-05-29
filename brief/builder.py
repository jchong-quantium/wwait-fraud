"""
builder.py — AI Case Brief assembler for fraud investigation triage.

Assembles a structured 7-block JSON case brief per vendor from four BigQuery
pipeline tables, then optionally generates a 5-section HTML investigation report
via Gemini on Vertex AI.

Part of: Woolworths Fraud Analytics Programme — Track B (AI-enabled triage).

Data sources (all in {GCP_PROJECT_ID}.{BQ_DATASET}):
    vendor_features     — peer-normalised spend/activity metrics (93 cols)
    vendor_attributes   — vendor master data (25 cols)
    base_transaction    — PO + invoice grain transaction data (29 cols)
    employee_attributes — employee master data (11 cols)

Usage:
    # CLI — builds brief for vendor with most transactions and saves JSON
    python3 brief/builder.py

    # CLI — specific vendor
    python3 brief/builder.py <vendor_number>

    # Programmatic
    from brief.builder import build_case_brief, build_and_generate
    brief = build_case_brief("V12345", tier="1")
    html  = build_and_generate("V12345", tier="1")

Authentication:
    Uses Application Default Credentials (ADC) or GOOGLE_APPLICATION_CREDENTIALS.
    No credentials are hardcoded (CWE-798).

Configuration (all via .env or environment):
    GCP_PROJECT_ID      — GCP project for BigQuery client
    BQ_DATASET          — BigQuery dataset containing pipeline tables
    GCP_LOCATION        — Vertex AI region (e.g. us-central1)
    GEMINI_MODEL        — Gemini model ID (default: gemini-2.5-flash)
"""

import json
import logging
import os
import re
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import pandas as pd
from dotenv import load_dotenv
from google import genai  # google-genai — Vertex AI / Gemini SDK
from google.genai.types import HttpOptions
from google.cloud import bigquery, storage
from google.cloud.exceptions import GoogleCloudError, NotFound

# ── Logging — structured format for Cloud Run compatibility ───────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

# ── Config — all sourced from environment, no credentials hardcoded (CWE-798) ─
load_dotenv()

GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
BQ_DATASET     = os.environ.get("BQ_DATASET")
GCP_LOCATION   = os.environ.get("GCP_LOCATION", "us-central1")
BQ_LOCATION    = os.environ.get("BQ_LOCATION", "US")
GEMINI_MODEL   = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
GCS_BUCKET     = os.environ.get("GCS_BUCKET")
# GCS may be in a different GCP project — defaults to GCP_PROJECT_ID if not set
GCS_PROJECT_ID = os.environ.get("GCS_PROJECT_ID") or GCP_PROJECT_ID

MELBOURNE_TZ      = ZoneInfo("Australia/Melbourne")
PIPELINE_VERSION  = "1.0.0"

# Payment terms codes treated as fast-payment (<= 7 days)
FAST_PAYMENT_TERMS_CODES = frozenset({"N001"})

# Proportion of transactions using fast terms required to raise payment_within_7d_flag
FAST_PAYMENT_TERMS_THRESHOLD = 0.20

# Status substrings that indicate a blocked or rejected payment / PO
BLOCKED_STATUS_PATTERNS = frozenset({"reject", "fail", "block", "cancel", "denied"})

# Path to the system prompt loaded by generate_case_brief_html()
PROMPTS_DIR = Path(__file__).parent / "prompts"


# ── Config validation ─────────────────────────────────────────────────────────

def _require_config() -> None:
    """Raise EnvironmentError if mandatory environment variables are absent."""
    missing = [v for v in ("GCP_PROJECT_ID", "BQ_DATASET") if not os.environ.get(v)]
    if missing:
        raise EnvironmentError(
            f"Required environment variables not set: {', '.join(missing)}. "
            "Copy .env.example to .env and populate the values."
        )


# ── BigQuery helpers ──────────────────────────────────────────────────────────

def _bq_client() -> bigquery.Client:
    """Return a BigQuery client using ADC — no credentials passed explicitly."""
    return bigquery.Client(project=GCP_PROJECT_ID, location=BQ_LOCATION)


def _table(name: str) -> str:
    """Return a fully-qualified BigQuery table reference.

    Table names are hardcoded constants in this module — not user-supplied —
    so there is no SQL injection risk here (CWE-89).
    """
    return f"`{GCP_PROJECT_ID}.{BQ_DATASET}.{name}`"


# ── Scalar helpers ────────────────────────────────────────────────────────────

def _to_python(val: Any) -> Any:
    """Recursively convert pandas/numpy scalars to JSON-serialisable Python types."""
    if val is None:
        return None
    # Catch NaN / NaT without importing numpy directly
    if isinstance(val, float) and val != val:
        return None
    try:
        import pandas as _pd  # already imported at top — kept local for clarity
        if _pd.isnull(val):
            return None
    except (TypeError, ValueError):
        pass
    if hasattr(val, "item"):          # numpy scalar → Python scalar
        return val.item()
    if isinstance(val, (date, datetime)):
        return val.isoformat()
    # BigQuery NUMERIC columns are returned as decimal strings by the REST API
    # fallback (e.g. "35902812.760000000"). Convert to float only when the
    # string is purely a decimal number — leaves IDs and status strings intact.
    if isinstance(val, str) and re.fullmatch(r"-?\d+\.\d+", val.strip()):
        return float(val)
    if isinstance(val, dict):
        return {k: _to_python(v) for k, v in val.items()}
    if isinstance(val, list):
        return [_to_python(v) for v in val]
    return val


def _col(df: pd.DataFrame, col: str, default: Any = None) -> Any:
    """Return the first non-null value of col from df, converted to Python type.

    Returns default if df is empty, col is absent, or all values are null.
    Handles duplicate rows defensively — safe to call on un-deduplicated data.
    """
    if df.empty or col not in df.columns:
        return default
    non_null = df[col].dropna()
    if non_null.empty:
        return default
    return _to_python(non_null.iloc[0])


def _now_melbourne() -> str:
    """Return the current Melbourne datetime as an ISO-8601 string (AEST/AEDT)."""
    return datetime.now(tz=MELBOURNE_TZ).isoformat()


def _contains_blocked_pattern(value: Any) -> bool:
    """Return True if value contains any blocked/rejected status substring."""
    if value is None:
        return False
    return any(p in str(value).lower() for p in BLOCKED_STATUS_PATTERNS)


# ── Data loading ──────────────────────────────────────────────────────────────

def load_vendor_data(
    vendor_number: str,
    client: bigquery.Client | None = None,
) -> dict[str, pd.DataFrame]:
    """Load all four pipeline tables for a single vendor.

    vendor_features, vendor_attributes, and base_transaction are filtered to
    the given vendor_number via parameterised queries (CWE-89).
    employee_attributes is loaded in full — it is a small reference table used
    for cross-vendor bank-detail matching.

    Args:
        vendor_number: BigQuery STRING key identifying the vendor.
        client: optional pre-existing BigQuery client; one is created if absent.

    Returns:
        Dict with keys: vendor_features, vendor_attributes,
                        base_transaction, employee_attributes.

    Raises:
        ValueError: if vendor_number is not a non-empty string.
        GoogleCloudError: if any BigQuery query fails.
    """
    # Input validation — defence-in-depth even though vendor_number is internal
    if not isinstance(vendor_number, str) or not vendor_number.strip():
        raise ValueError(
            f"vendor_number must be a non-empty string, got: {vendor_number!r}"
        )
    vn = vendor_number.strip()

    if client is None:
        client = _bq_client()
    results: dict[str, pd.DataFrame] = {}

    # Parameterised queries — prevent SQL injection (CWE-89)
    vn_param = [bigquery.ScalarQueryParameter("vendor_number", "STRING", vn)]
    vn_cfg   = bigquery.QueryJobConfig(query_parameters=vn_param)

    for tbl in ("vendor_features", "vendor_attributes"):
        sql = (
            f"SELECT * FROM {_table(tbl)} "
            "WHERE vendor_number = @vendor_number"
        )
        logger.info("Loading %s for vendor %s", tbl, vn)
        results[tbl] = client.query(sql, job_config=vn_cfg).to_dataframe()

    sql = (
        f"SELECT * FROM {_table('base_transaction')} "
        "WHERE vendor_number = @vendor_number"
    )
    logger.info("Loading base_transaction for vendor %s", vn)
    results["base_transaction"] = client.query(sql, job_config=vn_cfg).to_dataframe()

    # employee_attributes: full table load — small reference table
    # TODO: if this table grows large, push the bank-detail join into BigQuery instead
    logger.info("Loading employee_attributes (full table)")
    try:
        results["employee_attributes"] = client.query(
            f"SELECT * FROM {_table('employee_attributes')}"
        ).to_dataframe()
    except (GoogleCloudError, NotFound) as exc:
        # Table may not exist yet — return empty DataFrame; bank match will be null
        logger.warning(
            "employee_attributes unavailable (%s) — bank match will be null", exc
        )
        results["employee_attributes"] = pd.DataFrame()

    return results


def _load_sibling_vendor_data(
    supplier_id: str,
    client: bigquery.Client,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Return (sibling_va, sibling_vf) for all vendors sharing supplier_id.

    Returns two empty DataFrames if supplier_id is blank or no siblings exist.
    """
    if not supplier_id or not str(supplier_id).strip():
        return pd.DataFrame(), pd.DataFrame()

    sid = str(supplier_id).strip()

    # Parameterised query (CWE-89) — supplier_id originates from BigQuery
    # but is still treated as untrusted input (defence-in-depth)
    sid_param = [bigquery.ScalarQueryParameter("supplier_id", "STRING", sid)]
    sid_cfg   = bigquery.QueryJobConfig(query_parameters=sid_param)

    vnums_df = client.query(
        f"SELECT DISTINCT vendor_number "
        f"FROM {_table('vendor_attributes')} "
        "WHERE supplier_id = @supplier_id",
        job_config=sid_cfg,
    ).to_dataframe()

    if vnums_df.empty:
        return pd.DataFrame(), pd.DataFrame()

    vnums = [str(v) for v in vnums_df["vendor_number"].dropna().tolist()]
    if not vnums:
        return pd.DataFrame(), pd.DataFrame()

    # Use UNNEST with an array parameter — avoids string-interpolated IN clause
    vn_list_param = [bigquery.ArrayQueryParameter("vendor_numbers", "STRING", vnums)]
    vn_list_cfg   = bigquery.QueryJobConfig(query_parameters=vn_list_param)

    sibling_va = client.query(
        f"SELECT * FROM {_table('vendor_attributes')} "
        "WHERE vendor_number IN UNNEST(@vendor_numbers)",
        job_config=vn_list_cfg,
    ).to_dataframe()

    sibling_vf = client.query(
        f"SELECT * FROM {_table('vendor_features')} "
        "WHERE vendor_number IN UNNEST(@vendor_numbers)",
        job_config=vn_list_cfg,
    ).to_dataframe()

    return sibling_va, sibling_vf


# ── Block 1 — Vendor Profile ──────────────────────────────────────────────────

def build_vendor_profile(
    va: pd.DataFrame,
    vf: pd.DataFrame,
    tier: str | None = None,
) -> dict:
    """Block 1: vendor identity, classification, and derived age.

    Source:
        vendor_attributes — deduplicated (first non-null value per field)
        vendor_features   — fallback for category fields absent from va
    """
    # vendor_age_days: derived — days between vendor_creation_date and today (Melbourne)
    vendor_age_days = None
    creation_raw = _col(va, "vendor_creation_date")
    if creation_raw:
        try:
            creation = date.fromisoformat(str(creation_raw).split("T")[0])
            today_melb = datetime.now(tz=MELBOURNE_TZ).date()
            vendor_age_days = (today_melb - creation).days
        except (ValueError, TypeError):
            pass

    def _cat(col: str) -> Any:
        """Category fields: prefer vendor_attributes, fall back to vendor_features."""
        val = _col(va, col)
        return val if val is not None else _col(vf, col)

    return {
        "vendor_number":        _col(va, "vendor_number") or _col(vf, "vendor_number"),
        "vendor_name":          _col(va, "vendor_name")   or _col(vf, "vendor_name"),
        "supplier_category_l1": _cat("supplier_category_l1"),
        "supplier_category_l2": _cat("supplier_category_l2"),
        "supplier_category_l3": _cat("supplier_category_l3"),
        # vendor_attributes stores country as 'country'; vendor_features as 'supplier_country'
        "supplier_country":     _col(va, "country") or _col(vf, "supplier_country"),
        "local_supplier_flag":  _col(va, "local_supplier_flag"),
        "vendor_status":        _col(va, "vendor_status"),
        "vendor_creation_date": creation_raw,
        "vendor_age_days":      vendor_age_days,
        "vendor_abn":           _col(va, "vendor_abn"),
        "tier":                 tier,
    }


# ── Block 2 — Anomaly Scores ──────────────────────────────────────────────────

def build_anomaly_scores(vf: pd.DataFrame) -> dict:
    """Block 2: peer-normalised anomaly scores and percentile ranks.

    Dynamically discovers all peer_pct_rank_* columns from vendor_features.
    For each metric, the peer_comparison dict contains:
        vendor_value, peer_median, peer_mean, pct_rank.

    Stubs (TODO):
        composite_anomaly_score — requires scoring layer (Track B Phase 2).
            Candidate: weighted average of top-N peer_pct_rank values.
        scoring_methods         — dict of method_name → {score, weight} when built.
        consensus_flag          — True if majority of scoring methods flag this vendor.
    """
    if vf.empty:
        return {
            "peer_group":             None,
            "peer_group_size":        None,
            "peer_comparison":        {},
            "composite_anomaly_score": None,  # TODO: scoring layer (Track B Phase 2)
            "scoring_methods":        {},      # TODO: populated by scoring module
            "consensus_flag":         None,    # TODO: True if majority of methods flag vendor
        }

    row = vf.iloc[0]

    # Dynamically discover metrics via peer_pct_rank_* column naming convention
    pct_rank_cols = [c for c in vf.columns if c.startswith("peer_pct_rank_")]

    peer_comparison: dict[str, dict] = {}
    for pct_col in pct_rank_cols:
        feature = pct_col[len("peer_pct_rank_"):]   # strip prefix → raw feature name
        peer_comparison[feature] = {
            "vendor_value": _to_python(row.get(feature)),
            "peer_median":  _to_python(row.get(f"peer_median_{feature}")),
            "peer_mean":    _to_python(row.get(f"peer_mean_{feature}")),
            "pct_rank":     _to_python(row.get(pct_col)),
        }

    return {
        "peer_group":              _col(vf, "supplier_category_l2"),
        "peer_group_size":         _col(vf, "peer_group_size"),
        "peer_comparison":         peer_comparison,
        "composite_anomaly_score": None,  # TODO: scoring layer (Track B Phase 2)
        "scoring_methods":         {},    # TODO: populated by scoring module
        "consensus_flag":          None,  # TODO: True if majority of methods flag vendor
    }


# ── Block 3 — Routine Hits ────────────────────────────────────────────────────

def build_routine_hits() -> dict:
    """Block 3: rules-based routine detection hits for this vendor.

    Stubbed pending integration of the routine hits feed.

    TODO: join to routine_hits table (or case_brief_inputs view) once available.
    Expected schema per hit:
        routine_id:         str   — identifier of the routine that fired
        routine_category:   str   — e.g. "Duplicate Invoice", "Split PO"
        hit_count:          int   — number of transactions matching the routine
        hit_dollar_value:   float — total spend across matching transactions
        consistency_score:  float — 0–1, how consistently the routine fires for vendor
        period:             str   — e.g. "2025-01 to 2025-12"
    """
    return {
        # TODO: populate from routine_hits feed when available
        "hits": [],
    }


# ── Block 4 — Binary Flags ────────────────────────────────────────────────────

def build_binary_flags(
    bt: pd.DataFrame,
    va: pd.DataFrame,
    emp: pd.DataFrame,
) -> dict:
    """Block 4: binary risk flags derived from transactions, vendor, and employee data.

    NULL SEMANTICS (CRITICAL):
        None  → underlying data not collected / check cannot be performed
        False → data available, check performed, result is negative
        True  → data available, check performed, flag raised

    Never set a flag to False when the underlying data column is null.

    Flags:
        employee_bank_match     — vendor bank BSB+account matches an employee record.
                                  NULL pending dim_lfbk_vendor_bank_details_v access [D1].
        doa_breach_flag         — approver exceeded their Delegation of Authority limit.
                                  NULL pending audit_group_enablement.doa access [D2].
        blocked_payment_flag    — payment blocked/rejected in reconciliation or PO status.
                                  Computable from current data → True or False.
        payment_within_7d_flag  — proxy flag: >= 20% of transactions use N001 (7-day) terms.
                                  payment_date is NULL (Ariba only) so terms are used as proxy.
        collusion_indicator     — requires employee_bank_match + approval concentration
                                  + payment timing anomaly. NULL while bank data is absent.
    """

    # ── employee_bank_match ───────────────────────────────────────────────────
    # vendor_bank_bsb and vendor_bank_account are NULL for all vendors pending
    # access to dim_lfbk_vendor_bank_details_v [D1 in vendor_attributes.sql].
    # Return None — check cannot be performed with absent data.
    vendor_bsb  = _col(va, "vendor_bank_bsb")
    vendor_acct = _col(va, "vendor_bank_account")

    employee_bank_match       = None   # None = data not collected
    matched_employee_name     = None
    matched_employee_job_title = None

    if vendor_bsb is not None and vendor_acct is not None and not emp.empty:
        # Both vendor and employee bank data present — perform the match
        # TODO: confirm employee_bank_bsb / employee_bank_account column names
        #       once employee_attributes is fully populated
        has_emp_cols = (
            "employee_bank_bsb"     in emp.columns
            and "employee_bank_account" in emp.columns
        )
        if has_emp_cols:
            match_mask = (
                (emp["employee_bank_bsb"].astype(str)     == str(vendor_bsb))
                & (emp["employee_bank_account"].astype(str) == str(vendor_acct))
            )
            matched = emp[match_mask]
            if not matched.empty:
                employee_bank_match = True
                # TODO: confirm first_name / last_name / job_title col names in
                #       employee_attributes once the table is populated
                fn = _col(matched, "first_name", "") or ""
                ln = _col(matched, "last_name",  "") or ""
                matched_employee_name      = (f"{fn} {ln}".strip()) or None
                matched_employee_job_title = _col(matched, "job_title")
            else:
                employee_bank_match = False
        # else: employee_attributes exists but columns are missing — leave None

    # ── doa_breach_flag ───────────────────────────────────────────────────────
    # approver_doa_annual_limit is NULL for all rows pending [D2].
    # TODO: implement once audit_group_enablement.doa access is granted.
    #       Logic: True if any row has po_spend > approver_doa_annual_limit.
    doa_breach_flag = None   # None = data not collected

    # ── blocked_payment_flag ──────────────────────────────────────────────────
    # Derived from reconciliation_status or po_status containing reject/fail patterns.
    # Underlying data IS available → returns True or False (never None).
    blocked_payment_flag: bool | None = None
    if not bt.empty:
        rs_blocked = (
            bt["reconciliation_status"].apply(_contains_blocked_pattern)
            if "reconciliation_status" in bt.columns
            else pd.Series(False, index=bt.index)
        )
        po_blocked = (
            bt["po_status"].apply(_contains_blocked_pattern)
            if "po_status" in bt.columns
            else pd.Series(False, index=bt.index)
        )
        blocked_payment_flag = bool((rs_blocked | po_blocked).any())

    # ── payment_within_7d_flag ────────────────────────────────────────────────
    # payment_date is NULL for all Ariba rows (SAP branch pending [D1]).
    # Proxy: True if >= FAST_PAYMENT_TERMS_THRESHOLD of transactions carry an
    # N001 (7-day) payment terms code.
    payment_within_7d_flag: bool | None = None
    fast_payment_terms_count = 0

    if not bt.empty and "payment_terms" in bt.columns:
        total_txns = len(bt)
        fast_mask = bt["payment_terms"].apply(
            lambda x: any(code in str(x) for code in FAST_PAYMENT_TERMS_CODES)
            if pd.notna(x) else False
        )
        fast_payment_terms_count = int(fast_mask.sum())
        if total_txns > 0:
            payment_within_7d_flag = (
                fast_payment_terms_count / total_txns >= FAST_PAYMENT_TERMS_THRESHOLD
            )

    # ── flag_details ──────────────────────────────────────────────────────────
    acted_on_behalf_of_count  = 0
    rejected_invoices_count   = 0
    rejected_po_count         = 0
    approval_concentration: dict[str, float] = {}
    payment_terms_breakdown: dict[str, int]  = {}

    if not bt.empty:
        if "acted_on_behalf_of" in bt.columns:
            acted_on_behalf_of_count = int(bt["acted_on_behalf_of"].eq(True).sum())

        if "invoice_status" in bt.columns:
            rejected_invoices_count = int(
                bt["invoice_status"].apply(_contains_blocked_pattern).sum()
            )

        if "po_status" in bt.columns:
            rejected_po_count = int(
                bt["po_status"].apply(_contains_blocked_pattern).sum()
            )

        # approval_concentration: share of total transactions handled by each approver
        # approved_by_user = Real_User from Silver_Ariba_Approvals_v (actual approver)
        if "approved_by_user" in bt.columns:
            approver_counts = bt["approved_by_user"].dropna().value_counts()
            total_approved  = int(approver_counts.sum())
            if total_approved > 0:
                approval_concentration = {
                    str(approver): round(int(count) / total_approved, 4)
                    for approver, count in approver_counts.items()
                }

        if "payment_terms" in bt.columns:
            terms_counts = bt["payment_terms"].dropna().value_counts()
            payment_terms_breakdown = {
                str(terms): int(count) for terms, count in terms_counts.items()
            }

    # ── collusion_indicator ───────────────────────────────────────────────────
    # Requires ALL THREE conditions simultaneously:
    #   1. employee_bank_match (None — bank data not yet collected)
    #   2. approval_concentration anomaly (computable)
    #   3. payment_within_7d_flag (computable)
    # Since condition 1 is None, the full check cannot be performed.
    # Return None — not False — per null semantics above.
    # TODO: implement collusion_indicator once employee bank data is available [D1].
    collusion_indicator = None   # None = prerequisite data (bank details) not collected

    return {
        "employee_bank_match":        employee_bank_match,
        "matched_employee_name":      matched_employee_name,
        "matched_employee_job_title": matched_employee_job_title,
        "doa_breach_flag":            doa_breach_flag,
        "blocked_payment_flag":       blocked_payment_flag,
        "payment_within_7d_flag":     payment_within_7d_flag,
        "collusion_indicator":        collusion_indicator,
        "flag_details": {
            "acted_on_behalf_of_count":  acted_on_behalf_of_count,
            "rejected_invoices_count":   rejected_invoices_count,
            "rejected_po_count":         rejected_po_count,
            "approval_concentration":    approval_concentration,
            "fast_payment_terms_count":  fast_payment_terms_count,
            "payment_terms_breakdown":   payment_terms_breakdown,
        },
    }


# ── Block 5 — Exposure ────────────────────────────────────────────────────────

def build_exposure(
    vf: pd.DataFrame,
    va: pd.DataFrame,
    sibling_vf: pd.DataFrame | None = None,
) -> dict:
    """Block 5: financial exposure estimates for this vendor and its supplier group.

    supplier_combined_exposure sums total_po_spend_12m across all vendors sharing
    the same supplier_id. Currently always None because supplier_id is NULL for
    all vendors [L1 in vendor_attributes.sql] — logic is built and will activate
    once the supplier hierarchy is available.

    Stubs (TODO):
        unrealised_fraud_value  — requires fraud rate × exposure model (Track B Phase 2).
        potential_fraud_value   — requires case outcome data (Track B Phase 3).
    """
    total_po_spend_12m      = _col(vf, "total_po_spend_12m")
    total_invoice_spend_12m = _col(vf, "total_invoice_spend_12m")
    total_payment_amount_12m = _col(vf, "total_payment_amount_12m")

    # supplier_combined_exposure: sum of po_spend_12m across all sibling vendors
    # (including self). supplier_id is currently NULL for all vendors [L1].
    # TODO: will populate automatically once supplier hierarchy data is available.
    supplier_combined_exposure = None
    if (
        sibling_vf is not None
        and not sibling_vf.empty
        and "total_po_spend_12m" in sibling_vf.columns
    ):
        combined = sibling_vf["total_po_spend_12m"].sum()
        supplier_combined_exposure = _to_python(combined) if combined > 0 else None

    return {
        "total_po_spend_12m":       total_po_spend_12m,
        "total_invoice_spend_12m":  total_invoice_spend_12m,
        "total_payment_amount_12m": total_payment_amount_12m,
        # TODO: unrealised_fraud_value = fraud_rate_estimate × total_po_spend_12m
        #       Fraud rate estimate requires scoring layer (Track B Phase 2).
        "unrealised_fraud_value":   None,
        # TODO: potential_fraud_value requires historical case outcomes to calibrate
        #       (Track B Phase 3 — post-investigation feedback loop).
        "potential_fraud_value":    None,
        "supplier_combined_exposure": supplier_combined_exposure,
    }


# ── Block 6 — Top Flagged Transactions ───────────────────────────────────────

def build_top_transactions(bt: pd.DataFrame, top_n: int = 10) -> dict:
    """Block 6: top N transactions by po_spend descending.

    approved_by_user is used (Real_User from Silver_Ariba_Approvals_v).
    approver_last is intentionally excluded — it is a PO-header value repeated
    across all rows and carries no per-transaction signal.

    Stubs (TODO):
        routine_hits per transaction — requires join to routine_hits feed.
        flagged_transaction_count   — count of transactions with >= 1 routine hit.
    """
    transaction_columns = [
        "transaction_id",
        "po_number",
        "po_date",
        "invoice_date",
        "invoice_id",
        "po_spend",
        "invoice_amount_excl_tax",
        "payment_amount",
        "approved_by_user",      # Real approver (Real_User) — NOT approver_last
        "nominated_approver",
        "acted_on_behalf_of",
        "requestor",
        "po_status",
        "invoice_status",
        "reconciliation_status",
        "payment_terms",
        "system",
    ]

    if bt.empty:
        return {
            "total_transaction_count":   0,
            "flagged_transaction_count": 0,   # TODO: populate from routine_hits feed
            "transactions":              [],
        }

    sorted_bt = bt.sort_values("po_spend", ascending=False, na_position="last")
    top       = sorted_bt.head(top_n)

    transactions: list[dict] = []
    for _, row in top.iterrows():
        txn: dict[str, Any] = {
            col: _to_python(row.get(col)) for col in transaction_columns
        }
        # TODO: routine_hits per transaction requires join to routine_hits feed.
        #       Expected schema: [{routine_id, routine_category, hit_count}]
        txn["routine_hits"] = []
        transactions.append(txn)

    return {
        "total_transaction_count":   len(bt),
        # TODO: flagged_transaction_count = count of transactions with >= 1 routine hit.
        #       Stub as 0 until routine_hits feed is integrated.
        "flagged_transaction_count": 0,
        "transactions":              transactions,
    }


# ── Block 7 — Related Vendor IDs ─────────────────────────────────────────────

def build_related_vendors(
    vendor_number: str,
    va: pd.DataFrame,
    sibling_va: pd.DataFrame,
    sibling_vf: pd.DataFrame,
    tier: str | None = None,
) -> dict:
    """Block 7: other vendors in the same supplier group.

    Only populated for Tier 1 and Tier 2 vendors — higher tiers get an empty
    block to reduce noise in lower-priority investigations.

    Returns empty if supplier_id is null.

    Note: supplier_id is currently NULL for all vendors [L1 in vendor_attributes.sql].
    This block will auto-populate once the supplier hierarchy is available.
    """
    tier_str = str(tier).strip() if tier is not None else None

    # Only populate for Tier 1/2
    if tier_str not in (None, "1", "2", "Tier 1", "Tier 2"):
        return {
            "supplier_id":     None,
            "related_vendors": [],
            "combined_exposure": None,
        }

    supplier_id = _col(va, "supplier_id")
    if not supplier_id:
        # supplier_id is NULL for all vendors currently — see [L1] in vendor_attributes.sql
        # TODO: activate once supplier hierarchy data is sourced (raise with Gopi)
        return {
            "supplier_id":     None,
            "related_vendors": [],
            "combined_exposure": None,
        }

    related: list[dict] = []
    combined_po_12m = 0.0

    for _, sib_row in sibling_va.iterrows():
        sib_vn = _to_python(sib_row.get("vendor_number"))
        if sib_vn == vendor_number:
            continue   # exclude self

        sib_vf_rows = (
            sibling_vf[sibling_vf["vendor_number"] == sib_vn]
            if not sibling_vf.empty else pd.DataFrame()
        )

        sib_po_12m = float(_col(sib_vf_rows, "total_po_spend_12m") or 0.0)
        combined_po_12m += sib_po_12m

        # Key anomaly signals for this sibling vendor
        pct_ranks: dict[str, Any] = {}
        if not sib_vf_rows.empty:
            for col in sib_vf_rows.columns:
                if col.startswith("peer_pct_rank_"):
                    pct_ranks[col] = _to_python(sib_vf_rows.iloc[0].get(col))

        related.append({
            "vendor_number":      sib_vn,
            "vendor_name":        _to_python(sib_row.get("vendor_name")),
            "total_po_spend_12m": sib_po_12m,
            "anomaly_scores":     pct_ranks,
        })

    # Add self to combined exposure total
    self_vf   = (
        sibling_vf[sibling_vf["vendor_number"] == vendor_number]
        if not sibling_vf.empty else pd.DataFrame()
    )
    combined_po_12m += float(_col(self_vf, "total_po_spend_12m") or 0.0)

    return {
        "supplier_id":     supplier_id,
        "related_vendors": related,
        "combined_exposure": round(combined_po_12m, 2) if combined_po_12m else None,
    }


# ── Main assembly ─────────────────────────────────────────────────────────────

def build_case_brief(vendor_number: str, tier: str | None = None) -> dict:
    """Assemble a complete case brief for a single vendor.

    Returns a dict with a meta block and all 7 content blocks.
    Handles missing data gracefully — vendors absent from any table receive
    null/empty values rather than raising an error.

    Args:
        vendor_number: BigQuery STRING key identifying the vendor.
        tier: optional investigation tier ("1", "2", "3", "Tier 1", etc.).
              Affects Block 7 population (only Tier 1/2 get related vendors).

    Returns:
        Structured dict ready for JSON serialisation or LLM prompt injection.

    Raises:
        EnvironmentError: if GCP_PROJECT_ID or BQ_DATASET are not set.
        ValueError: if vendor_number is not a non-empty string.
        GoogleCloudError: if any required BigQuery query fails.
    """
    _require_config()

    if not isinstance(vendor_number, str) or not vendor_number.strip():
        raise ValueError(
            f"vendor_number must be a non-empty string, got: {vendor_number!r}"
        )
    vn = vendor_number.strip()
    logger.info("Building case brief for vendor %s (tier=%s)", vn, tier)

    client = _bq_client()
    data = load_vendor_data(vn, client=client)
    va   = data["vendor_attributes"]
    vf   = data["vendor_features"]
    bt   = data["base_transaction"]
    emp  = data["employee_attributes"]

    # Load sibling vendor data for Block 5 (exposure) and Block 7 (related vendors)
    # supplier_id is currently NULL for all vendors [L1] — queries return empty DFs
    sibling_va = pd.DataFrame()
    sibling_vf = pd.DataFrame()
    supplier_id = _col(va, "supplier_id")
    if supplier_id:
        sibling_va, sibling_vf = _load_sibling_vendor_data(supplier_id, client)

    # Derive data window from invoice_date range in base_transaction
    data_window: dict[str, Any] = {"start": None, "end": None}
    if not bt.empty and "invoice_date" in bt.columns:
        valid_dates = bt["invoice_date"].dropna()
        if not valid_dates.empty:
            data_window["start"] = _to_python(valid_dates.min())
            data_window["end"]   = _to_python(valid_dates.max())

    return {
        "meta": {
            "vendor_number":    vn,
            "generated_at":     _now_melbourne(),   # Melbourne AEST/AEDT
            "data_window":      data_window,
            "pipeline_version": PIPELINE_VERSION,
        },
        "vendor_profile":    build_vendor_profile(va, vf, tier=tier),
        "anomaly_scores":    build_anomaly_scores(vf),
        "routine_hits":      build_routine_hits(),
        "binary_flags":      build_binary_flags(bt, va, emp),
        "exposure":          build_exposure(vf, va, sibling_vf=sibling_vf),
        "top_transactions":  build_top_transactions(bt),
        "related_vendors":   build_related_vendors(
            vn, va, sibling_va, sibling_vf, tier=tier
        ),
    }


def build_batch(
    vendor_numbers: list[str],
    tier_map: dict[str, str] | None = None,
) -> list[dict]:
    """Build case briefs for a list of vendor_numbers.

    Args:
        vendor_numbers: list of vendor_number strings to process.
        tier_map: optional dict mapping vendor_number → tier string.

    Returns:
        List of case brief dicts (one per vendor). Failed briefs are included
        with an error key rather than raising, so a single bad vendor does not
        abort the batch.
    """
    _require_config()
    tier_map = tier_map or {}
    briefs: list[dict] = []

    for vn in vendor_numbers:
        tier = tier_map.get(vn)
        try:
            briefs.append(build_case_brief(vn, tier=tier))
        except Exception as exc:
            logger.error("Failed to build brief for vendor %s: %s", vn, exc)
            briefs.append({
                "meta":  {"vendor_number": vn, "error": str(exc), "generated_at": _now_melbourne()},
                "error": True,
            })

    return briefs


# LLM integration — Gemini via Vertex AI 

# Cached at first call — prompt files are static at deploy time, no need to
# re-read them on every request in a Cloud Run container.
_SYSTEM_PROMPT_CACHE: str | None = None


def _load_system_prompt() -> str:
    """Load and combine the case brief instructions and HTML template.

    Reads two files from brief/prompts/ on first call, then returns the cached
    string for subsequent calls (files are static within a Cloud Run revision).

        prompt.md   — reasoning instructions and placeholder rules
        template.html — HTML template with [PLACEHOLDER] slots

    Raises:
        FileNotFoundError: if either file does not exist.
    """
    global _SYSTEM_PROMPT_CACHE
    if _SYSTEM_PROMPT_CACHE is not None:
        return _SYSTEM_PROMPT_CACHE

    # Paths constructed from a known constant directory — not user-supplied (CWE-22)
    prompt_path   = PROMPTS_DIR / "prompt.md"
    template_path = PROMPTS_DIR / "template.html"

    for path in (prompt_path, template_path):
        if not path.exists():
            raise FileNotFoundError(
                f"Required prompt file not found: {path}\n"
                "Ensure both brief/prompts/prompt.md and "
                "brief/prompts/template.html exist."
            )

    instructions = prompt_path.read_text(encoding="utf-8")
    template     = template_path.read_text(encoding="utf-8")

    _SYSTEM_PROMPT_CACHE = f"{instructions}\n\n### HTML Template\n\n{template}"
    return _SYSTEM_PROMPT_CACHE


def generate_case_brief_html(vendor_json: dict) -> str:
    """Generate a 5-section HTML investigation report from a case brief dict.

    Sends the structured case brief JSON to Gemini via Vertex AI, using the
    system prompt loaded from brief/prompts/case_brief.txt.

    Follows the same Vertex AI client pattern as test/test_gemini.py:
        genai.Client(vertexai=True, project=..., location=...)

    Args:
        vendor_json: the dict returned by build_case_brief().

    Returns:
        HTML string (5-section investigation report).

    Raises:
        EnvironmentError: if GCP_PROJECT_ID or GCP_LOCATION are not set.
        FileNotFoundError: if the system prompt file is missing.
    """
    if not GCP_PROJECT_ID:
        raise EnvironmentError("GCP_PROJECT_ID must be set in .env")

    system_prompt   = _load_system_prompt()
    vendor_json_str = json.dumps(vendor_json, indent=2, default=str)

    # Vertex AI client — 5-minute timeout guards against hung Cloud Run requests
    client = genai.Client(
        vertexai=True,
        project=GCP_PROJECT_ID,
        location=GCP_LOCATION,
        http_options=HttpOptions(timeout=300_000),
    )

    # Combine system prompt and case brief JSON into a single turn
    # The system prompt instructs the model on output format and structure;
    # the JSON block provides all vendor data for the report.
    contents = (
        f"{system_prompt}\n\n"
        "---\n\n"
        "## Case Brief JSON\n\n"
        f"```json\n{vendor_json_str}\n```"
    )

    logger.info(
        "Sending case brief for vendor %s to %s (Vertex AI, %s)",
        vendor_json.get("meta", {}).get("vendor_number", "unknown"),
        GEMINI_MODEL,
        GCP_LOCATION,
    )

    response = client.models.generate_content(
        model=GEMINI_MODEL,
        contents=contents,
    )

    return response.text


def upload_html_to_gcs(html: str, vendor_number: str, timestamp: str) -> str:
    """Upload a case brief HTML string to Cloud Storage.

    Uses ADC — no credentials hardcoded (CWE-798).
    Bucket name and project come from GCS_BUCKET / GCS_PROJECT_ID env vars.

    Args:
        html:          HTML content to upload.
        vendor_number: Used to construct the GCS object name.
        timestamp:     ISO-style timestamp string (e.g. "20260526T143000").

    Returns:
        gs:// URI of the uploaded object.

    Raises:
        EnvironmentError: if GCS_BUCKET is not set.
        google.cloud.exceptions.GoogleCloudError: on upload failure.
    """
    if not GCS_BUCKET:
        raise EnvironmentError(
            "GCS_BUCKET must be set in .env to upload case briefs to Cloud Storage."
        )

    gcs_client = storage.Client(project=GCS_PROJECT_ID)
    bucket     = gcs_client.bucket(GCS_BUCKET)
    # Store under briefs/<vendor_number>/ prefix for easy querying
    blob_name  = f"briefs/{vendor_number}/case_brief_{vendor_number}_{timestamp}.html"
    blob       = bucket.blob(blob_name)

    blob.upload_from_string(html, content_type="text/html; charset=utf-8")

    uri = f"gs://{GCS_BUCKET}/{blob_name}"
    logger.info("Case brief uploaded to %s", uri)
    return uri


def build_and_generate(vendor_number: str, tier: str | None = None) -> str:
    """End-to-end: build case brief JSON then generate HTML investigation report.

    Chains build_case_brief() → generate_case_brief_html().

    Args:
        vendor_number: BigQuery STRING key identifying the vendor.
        tier: optional investigation tier passed to build_case_brief().

    Returns:
        HTML string (5-section investigation report from Gemini).
    """
    brief = build_case_brief(vendor_number, tier=tier)
    return generate_case_brief_html(brief)


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    """Build a sample case brief and save it to a JSON file.

    Usage:
        python3 brief/builder.py                  # vendor with most txns
        python3 brief/builder.py <vendor_number>  # specific vendor
    """
    _require_config()
    client = _bq_client()

    if len(sys.argv) > 1:
        # Sanitise CLI argument — strip whitespace, cap length
        # vendor_number is a BigQuery STRING key (internal), not user-controlled data,
        # but we sanitise defensively as this is a system boundary (CWE-20)
        target_vendor = sys.argv[1].strip()[:128]
        if not target_vendor:
            sys.exit("ERROR: vendor_number argument is empty")
        logger.info("Using supplied vendor_number: %s", target_vendor)
    else:
        # Auto-select: vendor with the most transactions
        logger.info("No vendor_number supplied — finding vendor with most transactions")
        top_sql = (
            f"SELECT vendor_number, COUNT(*) AS txn_count "
            f"FROM {_table('base_transaction')} "
            "WHERE vendor_number IS NOT NULL "
            "GROUP BY vendor_number "
            "ORDER BY txn_count DESC "
            "LIMIT 1"
        )
        top_df = client.query(top_sql).to_dataframe()
        if top_df.empty:
            sys.exit("ERROR: base_transaction is empty — cannot auto-select sample vendor")
        target_vendor = str(top_df.iloc[0]["vendor_number"])
        txn_count     = int(top_df.iloc[0]["txn_count"])
        logger.info("Auto-selected vendor %s (%d transactions)", target_vendor, txn_count)

    brief = build_case_brief(target_vendor)

    ts         = datetime.now(tz=MELBOURNE_TZ).strftime("%Y%m%dT%H%M%S")
    output_dir = Path(__file__).parent / "output"
    output_dir.mkdir(exist_ok=True)

    # Save JSON so it can be pasted directly into the Gem
    json_path = output_dir / f"case_brief_{target_vendor}_{ts}.json"
    json_path.write_text(json.dumps(brief, indent=2, default=str), encoding="utf-8")
    logger.info("Case brief JSON saved to %s", json_path)

    # Generate HTML via Gemini and save locally
    logger.info("Generating HTML report via Gemini...")
    html      = generate_case_brief_html(brief)
    html_path = output_dir / f"case_brief_{target_vendor}_{ts}.html"
    html_path.write_text(html, encoding="utf-8")
    logger.info("Case brief HTML saved to %s", html_path)

    # Upload to Cloud Storage if GCS_BUCKET is configured
    if GCS_BUCKET:
        try:
            gcs_uri = upload_html_to_gcs(html, target_vendor, ts)
            logger.info("Uploaded to %s", gcs_uri)
        except (EnvironmentError, GoogleCloudError) as exc:
            logger.warning("GCS upload failed (local file still saved): %s", exc)
    else:
        logger.info("GCS_BUCKET not set — skipping Cloud Storage upload")
