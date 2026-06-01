"""
transaction_scorer.py — Transaction-level Isolation Forest scorer.

Reads from base_transaction in BigQuery, engineers features, fits an
Isolation Forest, computes SHAP on anomalies, and writes scores to the
transaction_scores table.

Ported from misc/Iforest_V3.py and misc/DataPrep.py. Key differences
from the prototype:
  - Reads from BigQuery instead of a local parquet file
  - Writes results back to BigQuery instead of local parquet
  - No local file I/O
  - Cloud Run Job entry point (runs to completion and exits)

Feature set: 12 features (Iforest v3 — PO-amount features excluded;
see misc/Iforest_V3.py header for rationale).

Configuration (all via .env or environment — no credentials hardcoded, CWE-798):
  GCP_PROJECT_ID  — GCP project for BigQuery
  BQ_DATASET      — BigQuery dataset
  BQ_LOCATION     — BigQuery location (optional, defaults to US)
"""

import logging
import os
import re
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import shap
from dotenv import load_dotenv
from sklearn.ensemble import IsolationForest

from scorer import bq_client, read_table, write_scores

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

# Config — all from environment, no credentials hardcoded (CWE-798)
load_dotenv()

MODEL_VERSION = "isoforest-txn-v3"

# ── Hyperparameters (matching Iforest_V3.py) ─────────────────────────────────
CONTAMINATION   = 0.02
N_ESTIMATORS    = 200
MAX_SAMPLES     = "auto"
PRIMARY_SEED    = 42
MIN_CC_SIZE     = 100  # cost centres with fewer rows are excluded from scoring

# ── Feature lists (v3: 12 features, PO-amount features excluded) ──────────────
# See misc/Iforest_V3.py header for rationale on excluded features.

# Amount and ratio features that receive within-CC normalisation
CC_NORMALISED = [
    "invoice_amount_excl_tax",
    "payment_amount",
    "tax_amount",
    "invoice_lag_to_terms_ratio",
    "approval_lag_invoice_to_terms_ratio",
]

# Features used as-is (no CC normalisation)
AS_IS_FEATURES = [
    "payment_terms_days",
    "days_invoice_minus_po",
    "days_approval_minus_po",
    "days_approval_minus_invoice",
    "payment_to_invoice_ratio",
    "approval_lag_po_to_terms_ratio",
    "tax_to_payment_ratio",
]

# Final 12-feature set fed to IsolationForest
ISOFOREST_FEATURES = [f"{c}_norm" for c in CC_NORMALISED] + AS_IS_FEATURES

# Columns read from base_transaction — hardcoded constants, not user-supplied (CWE-89)
BASE_TXN_COLUMNS = [
    "transaction_id",
    "vendor_number",
    "cost_centre",
    "po_date",
    "invoice_date",
    "approval_date",
    "invoice_amount_excl_tax",
    "payment_amount",
    "tax_amount",
    "payment_terms",
]


# ── Feature engineering ───────────────────────────────────────────────────────

def _extract_payment_terms_days(value) -> int:
    """Extract numeric payment days from a payment_terms description string.

    N005 / 'Pay immediately' / blank → 1 (treat as 1 day).
    Otherwise extracts the first integer before 'day' in the string.

    Ported from misc/DataPrep.py::extract_payment_days().
    """
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return 1
    s = str(value).strip()
    if not s:
        return 1
    if re.search(r"immediate|same\s*day", s, flags=re.IGNORECASE):
        return 1
    m = re.search(r"(\d+)\s*day", s, flags=re.IGNORECASE)
    return int(m.group(1)) if m else 1


def _apply_population_filters(df: pd.DataFrame) -> pd.DataFrame:
    """Apply population filters from DataPrep.py (F1–F5).

    Filters:
      F1 — po_date IS NOT NULL
      F2 — payment_amount IS NOT NULL AND > 0
      F3 — invoice_date >= 2024-01-01
      F4 — approval_date IS NOT NULL (4 features derived from it)

    Rows failing any filter are excluded from scoring.
    """
    n_raw = len(df)

    mask = (
        df["po_date"].notna()
        & df["payment_amount"].notna()
        & (df["payment_amount"] > 0)
        & (df["invoice_date"] >= pd.Timestamp("2024-01-01"))
        & df["approval_date"].notna()
    )

    df_filtered = df[mask].copy()
    n_dropped = n_raw - len(df_filtered)
    logger.info(
        "Population filters: %s → %s rows (%s dropped, %.1f%%)",
        f"{n_raw:,}", f"{len(df_filtered):,}",
        f"{n_dropped:,}", n_dropped / n_raw * 100 if n_raw else 0,
    )
    return df_filtered


def _engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    """Engineer all 12 IsoForest input features from base_transaction columns.

    Ported from misc/DataPrep.py cells 3, 5, 6, 7.
    """
    df = df.copy()

    # Contractual: parse payment terms days from raw string
    df["payment_terms_days"] = df["payment_terms"].apply(_extract_payment_terms_days)

    # Date differences (integer days)
    df["days_invoice_minus_po"] = (
        (df["invoice_date"] - df["po_date"]).dt.days
    )
    df["days_approval_minus_po"] = (
        (df["approval_date"] - df["po_date"]).dt.days
    )
    df["days_approval_minus_invoice"] = (
        (df["approval_date"] - df["invoice_date"]).dt.days
    )

    # Lag-to-terms ratios — guard against payment_terms_days = 0 (floor is 1,
    # but defensive replace in case of unexpected data)
    terms_safe = df["payment_terms_days"].replace(0, np.nan)
    df["invoice_lag_to_terms_ratio"] = (
        df["days_invoice_minus_po"] / terms_safe
    )
    df["approval_lag_po_to_terms_ratio"] = (
        df["days_approval_minus_po"] / terms_safe
    )
    df["approval_lag_invoice_to_terms_ratio"] = (
        df["days_approval_minus_invoice"] / terms_safe
    )

    # Amount ratios — 0-denominators → NaN (propagates naturally)
    df["payment_to_invoice_ratio"] = (
        df["payment_amount"]
        / df["invoice_amount_excl_tax"].replace(0, np.nan)
    )
    df["tax_to_payment_ratio"] = (
        df["tax_amount"]
        / df["payment_amount"].replace(0, np.nan)
    )

    return df


def _filter_min_cc_size(df: pd.DataFrame) -> pd.DataFrame:
    """Exclude cost centres with fewer than MIN_CC_SIZE rows.

    Small CCs don't provide enough within-CC context for reliable normalisation.
    Rows with NULL cost_centre are also excluded.
    """
    n_before = len(df)

    cc_size = df["cost_centre"].value_counts(dropna=True)
    large_cc = set(cc_size[cc_size >= MIN_CC_SIZE].index)
    df_filtered = df[df["cost_centre"].isin(large_cc)].copy()

    n_after = len(df_filtered)
    logger.info(
        "CC size filter (>= %d rows): %s → %s rows (%.1f%% dropped)",
        MIN_CC_SIZE,
        f"{n_before:,}", f"{n_after:,}",
        (n_before - n_after) / n_before * 100 if n_before else 0,
    )
    return df_filtered


def _apply_cc_normalisation(df: pd.DataFrame, feat: str) -> pd.DataFrame:
    """Apply within-cost-centre median+IQR normalisation for a single feature.

    Rows where cost_centre is NULL receive NaN for the _norm column
    (handled by median imputation in _build_model_matrix).

    Ported from misc/Iforest_V3.py::apply_within_cc_normalisation().
    """
    df = df.copy()

    cc_stats = (
        df[df["cost_centre"].notna()]
        .groupby("cost_centre")[feat]
        .agg(
            median="median",
            q1=lambda x: x.quantile(0.25),
            q3=lambda x: x.quantile(0.75),
        )
    )
    cc_stats["iqr"] = cc_stats["q3"] - cc_stats["q1"]
    # IQR = 0 means no spread within CC — set to 1 to avoid divide-by-zero
    cc_stats.loc[cc_stats["iqr"] == 0, "iqr"] = 1

    row_median = df["cost_centre"].map(cc_stats["median"])
    row_iqr    = df["cost_centre"].map(cc_stats["iqr"])
    df[f"{feat}_norm"] = (df[feat] - row_median) / row_iqr

    logger.info("  CC-normalised %s → %s_norm", feat, feat)
    return df


# ── Scoring ───────────────────────────────────────────────────────────────────

def _build_model_matrix(df: pd.DataFrame) -> pd.DataFrame:
    """Build the IsoForest feature matrix, handling nulls and infinities.

    Nulls are median-imputed. Infinities are replaced with NaN before imputation.
    Ported from misc/Iforest_V3.py step 3.
    """
    X = df[ISOFOREST_FEATURES].astype(float).copy()
    X = X.replace([np.inf, -np.inf], np.nan)

    null_counts = X.isna().sum()
    if null_counts.any():
        logger.warning(
            "Null values in model matrix — median-imputing:\n%s",
            null_counts[null_counts > 0].to_string(),
        )
        X = X.fillna(X.median())

    logger.info(
        "Model matrix: %s rows × %s features, nulls: %d, infs: %d",
        f"{X.shape[0]:,}", X.shape[1],
        X.isna().sum().sum(),
        np.isinf(X.values).sum(),
    )
    return X


def _fit_isoforest(X: pd.DataFrame) -> tuple[IsolationForest, np.ndarray, np.ndarray]:
    """Fit IsolationForest and return (model, anomaly_scores, is_anomaly).

    anomaly_score = -decision_function (higher = more anomalous).
    is_anomaly    = True for the top CONTAMINATION % of transactions.
    """
    iso = IsolationForest(
        n_estimators=N_ESTIMATORS,
        max_samples=MAX_SAMPLES,
        contamination=CONTAMINATION,
        random_state=PRIMARY_SEED,
        n_jobs=-1,
    )
    iso.fit(X)

    scores     = -iso.decision_function(X)
    is_anomaly = iso.predict(X) == -1

    logger.info(
        "IsoForest fit: %s anomalies flagged (top %.0f%% of %s)",
        f"{is_anomaly.sum():,}",
        CONTAMINATION * 100,
        f"{len(X):,}",
    )
    return iso, scores, is_anomaly


def _compute_shap(
    iso: IsolationForest,
    X_anom: pd.DataFrame,
) -> tuple[np.ndarray, np.ndarray]:
    """Compute SHAP values for anomalous transactions only.

    Returns (top_driver_indices, top_driver_shap_values) aligned to X_anom.
    """
    logger.info("Computing SHAP for %s anomalies ...", f"{len(X_anom):,}")
    explainer   = shap.TreeExplainer(iso)
    shap_values = explainer.shap_values(X_anom, check_additivity=False)

    abs_shap = np.abs(shap_values)
    top_idx  = np.argmax(abs_shap, axis=1)
    top_shap = abs_shap[np.arange(len(abs_shap)), top_idx]

    logger.info("SHAP complete")
    return top_idx, top_shap


# ── Main ──────────────────────────────────────────────────────────────────────

def _require_config() -> tuple[str, str]:
    """Validate required env vars and return (project, dataset)."""
    project = os.environ.get("GCP_PROJECT_ID")
    dataset = os.environ.get("BQ_DATASET")
    missing = [k for k, v in {"GCP_PROJECT_ID": project, "BQ_DATASET": dataset}.items() if not v]
    if missing:
        raise EnvironmentError(
            f"Required environment variables not set: {', '.join(missing)}. "
            "Copy .env.example to .env and populate the values."
        )
    return project, dataset


def main() -> None:
    logger.info("=" * 60)
    logger.info("Transaction scorer — %s", MODEL_VERSION)
    logger.info("=" * 60)

    project, dataset = _require_config()
    client = bq_client()

    # ── Step 1: Load ──────────────────────────────────────────────────────────
    logger.info("--- Step 1: Load base_transaction ---")
    df = read_table(client, project, dataset, "base_transaction", columns=BASE_TXN_COLUMNS)

    for col in ("po_date", "invoice_date", "approval_date"):
        df[col] = pd.to_datetime(df[col], errors="coerce")

    # ── Step 2: Population filters ────────────────────────────────────────────
    logger.info("--- Step 2: Population filters ---")
    df = _apply_population_filters(df)

    # ── Step 3: Feature engineering ───────────────────────────────────────────
    logger.info("--- Step 3: Feature engineering ---")
    df = _engineer_features(df)

    # ── Step 4: CC filter ─────────────────────────────────────────────────────
    logger.info("--- Step 4: CC size filter (min %d rows) ---", MIN_CC_SIZE)
    df = _filter_min_cc_size(df)

    if df.empty:
        logger.error("No rows remain after filters — aborting.")
        sys.exit(1)

    # ── Step 5: Within-CC normalisation ──────────────────────────────────────
    logger.info("--- Step 5: Within-CC normalisation ---")
    for feat in CC_NORMALISED:
        df = _apply_cc_normalisation(df, feat)

    # ── Step 6: Build model matrix ────────────────────────────────────────────
    logger.info("--- Step 6: Build model matrix ---")
    X = _build_model_matrix(df)

    # ── Step 7: Fit IsoForest ─────────────────────────────────────────────────
    logger.info("--- Step 7: Fit IsolationForest ---")
    iso, scores, is_anomaly = _fit_isoforest(X)

    # ── Step 8: SHAP on anomalies ─────────────────────────────────────────────
    logger.info("--- Step 8: SHAP on anomalies ---")
    anom_mask   = is_anomaly
    X_anom      = X[anom_mask]
    top_feature = np.full(len(df), None, dtype=object)
    top_shap    = np.full(len(df), np.nan)

    if len(X_anom) > 0:
        anom_top_idx, anom_top_shap = _compute_shap(iso, X_anom)
        top_feature[anom_mask] = [ISOFOREST_FEATURES[i] for i in anom_top_idx]
        top_shap[anom_mask]    = anom_top_shap

    # ── Step 9: Assemble output ───────────────────────────────────────────────
    logger.info("--- Step 9: Assemble output ---")
    scored_at = datetime.now(tz=timezone.utc)

    out = pd.DataFrame({
        "transaction_id":     df["transaction_id"].values,
        "vendor_number":      df["vendor_number"].values,
        "cost_centre":        df["cost_centre"].values,
        "anomaly_score":      scores,
        "is_anomaly":         is_anomaly,
        "top_driver_feature": top_feature,
        "top_driver_shap":    np.where(np.isnan(top_shap), None, top_shap),
        "model_version":      MODEL_VERSION,
        "scored_at":          scored_at,
    })

    logger.info(
        "Output: %s rows, %s anomalies (%.1f%%)",
        f"{len(out):,}",
        f"{out['is_anomaly'].sum():,}",
        out["is_anomaly"].mean() * 100,
    )

    # ── Step 10: Write to BigQuery ────────────────────────────────────────────
    logger.info("--- Step 10: Write to transaction_scores ---")
    write_scores(client, out, project, dataset, "transaction_scores")

    logger.info("=" * 60)
    logger.info("Scoring complete — %s transactions scored", f"{len(out):,}")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()