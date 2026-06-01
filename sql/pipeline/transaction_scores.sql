-- =============================================================================
-- transaction_scores — Isolation Forest anomaly scores at transaction grain
--
-- Schema stub: created empty by the SQL pipeline before the scorer runs.
-- Populated (WRITE_TRUNCATE) by scoring/transaction_scorer.py on each pipeline run.
--
-- COLUMNS:
--   transaction_id      — joins back to base_transaction
--   vendor_number       — for vendor-level rollup in vendor_scores
--   cost_centre         — the CC used for within-CC normalisation
--   anomaly_score       — IF score: higher = more anomalous
--                         (-decision_function output, so positive = anomalous)
--   is_anomaly          — TRUE if flagged by IF (top CONTAMINATION %)
--   top_driver_feature  — SHAP top driver feature name (anomalies only, else NULL)
--   top_driver_shap     — absolute SHAP value for top driver (anomalies only)
--   model_version       — scorer version for auditability
--   scored_at           — pipeline run timestamp
--
-- REFRESH:
--   Written by scoring/transaction_scorer.py — run after vendor_features, before vendor_scores.
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.transaction_scores`
(
  transaction_id      STRING    OPTIONS (description = 'FK to base_transaction'),
  vendor_number       STRING    OPTIONS (description = 'FK to vendor_scores rollup'),
  cost_centre         STRING    OPTIONS (description = 'CC used for normalisation'),
  anomaly_score       FLOAT64   OPTIONS (description = 'IF score — higher = more anomalous'),
  is_anomaly          BOOL      OPTIONS (description = 'TRUE if in top contamination %'),
  top_driver_feature  STRING    OPTIONS (description = 'SHAP top driver — anomalies only'),
  top_driver_shap     FLOAT64   OPTIONS (description = 'Absolute SHAP value for top driver'),
  model_version       STRING    OPTIONS (description = 'Scorer version string'),
  scored_at           TIMESTAMP OPTIONS (description = 'Pipeline run timestamp')
)