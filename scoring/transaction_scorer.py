"""
transaction_scorer.py — Transaction-level Isolation Forest scorer.

Reads the pre-engineered feature matrix from model_input in BigQuery,
fits an Isolation Forest, computes SHAP on anomalies, and writes scores
to the transaction_scores table.

All population filtering, feature engineering, within-CC normalisation,
and null imputation are handled upstream by sql/pipeline/model_input.sql.
Python is responsible only for the model fit and SHAP computation.

Feature set: 12 features (Iforest v3 — PO-amount features excluded;
see misc/Iforest_V3.py header for rationale).

Configuration (all via .env or environment — no credentials hardcoded, CWE-798):
  GCP_PROJECT_ID  — GCP project for BigQuery
  BQ_DATASET      — BigQuery dataset
  BQ_LOCATION     — BigQuery location (optional, defaults to US)
"""

import logging
import os
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

# ── Feature list (v3: 12 features, PO-amount features excluded) ───────────────
# Matches the output column order of sql/pipeline/model_input.sql.
# See misc/Iforest_V3.py header for rationale on excluded features.
ISOFOREST_FEATURES = [
    "invoice_amount_excl_tax_norm",
    "payment_amount_norm",
    "tax_amount_norm",
    "invoice_lag_to_terms_ratio_norm",
    "approval_lag_invoice_to_terms_ratio_norm",
    "payment_terms_days",
    "days_invoice_minus_po",
    "days_approval_minus_po",
    "days_approval_minus_invoice",
    "payment_to_invoice_ratio",
    "approval_lag_po_to_terms_ratio",
    "tax_to_payment_ratio",
]


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
    # model_input is a pre-engineered feature matrix produced by
    # sql/pipeline/model_input.sql — all filtering, normalisation, and
    # null imputation already applied; Python reads it as-is.
    logger.info("--- Step 1: Load model_input ---")
    df = read_table(client, project, dataset, "model_input")

    if df.empty:
        logger.error("model_input is empty — aborting.")
        sys.exit(1)

    # ── Step 2: Build model matrix ────────────────────────────────────────────
    logger.info("--- Step 2: Build model matrix ---")
    X = df[ISOFOREST_FEATURES].astype(float)

    # ── Step 3: Fit IsoForest ─────────────────────────────────────────────────
    logger.info("--- Step 3: Fit IsolationForest ---")
    iso, scores, is_anomaly = _fit_isoforest(X)

    # ── Step 4: SHAP on anomalies ─────────────────────────────────────────────
    logger.info("--- Step 4: SHAP on anomalies ---")
    anom_mask   = is_anomaly
    X_anom      = X[anom_mask]
    top_feature = np.full(len(df), None, dtype=object)
    top_shap    = np.full(len(df), np.nan)

    if len(X_anom) > 0:
        anom_top_idx, anom_top_shap = _compute_shap(iso, X_anom)
        top_feature[anom_mask] = [ISOFOREST_FEATURES[i] for i in anom_top_idx]
        top_shap[anom_mask]    = anom_top_shap

    # ── Step 5: Assemble output ───────────────────────────────────────────────
    logger.info("--- Step 5: Assemble output ---")
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

    # ── Step 6: Write to BigQuery ─────────────────────────────────────────────
    logger.info("--- Step 6: Write to transaction_scores ---")
    write_scores(client, out, project, dataset, "transaction_scores")

    logger.info("=" * 60)
    logger.info("Scoring complete — %s transactions scored", f"{len(out):,}")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()