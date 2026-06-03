-- =============================================================================
-- model_input — pre-engineered IsoForest feature matrix
-- =============================================================================
--
-- Applies population filters, engineers all 12 IsoForest features, filters
-- small cost centres, applies within-CC normalisation, and imputes any
-- remaining NULLs with global medians.
--
-- Output is a clean, ready-to-score table consumed directly by
-- scoring/transaction_scorer.py. Python is responsible only for the model
-- fit and SHAP computation.
--
-- FEATURE SET (12 features — Isoforest v3):
--   CC-normalised (5): invoice_amount_excl_tax_norm, payment_amount_norm,
--     tax_amount_norm, invoice_lag_to_terms_ratio_norm,
--     approval_lag_invoice_to_terms_ratio_norm
--   As-is (7): payment_terms_days, days_invoice_minus_po,
--     days_approval_minus_po, days_approval_minus_invoice,
--     payment_to_invoice_ratio, approval_lag_po_to_terms_ratio,
--     tax_to_payment_ratio
--
-- REFRESH:
--   Run after base_transaction and before transaction_scores (schema stub).
--   Order in run_pipeline.py: vendor_attributes → employee_attributes →
--   base_transaction → vendor_features → model_input → transaction_scores
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.model_input`
AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: Population filters + base feature engineering
--
-- Filters (match Python population filters F1–F4):
--   po_date IS NOT NULL
--   approval_date IS NOT NULL
--   payment_amount IS NOT NULL AND > 0
--   invoice_date >= INVOICE_DATE_FLOOR  ← update this when extending the window
--   cost_centre IS NOT NULL             ← required for CC normalisation
--
-- payment_terms_days: parses the raw payment_terms string to an integer.
--   Immediate / blank / N005 → 1. Otherwise extracts first integer before 'day'.
--   Matches _extract_payment_terms_days() in the original transaction_scorer.py.
-- ─────────────────────────────────────────────────────────────────────────────
base AS (
  SELECT
    transaction_id,
    vendor_number,
    cost_centre,
    invoice_amount_excl_tax,
    payment_amount,
    tax_amount,

    CASE
      WHEN payment_terms IS NULL OR TRIM(payment_terms) = ''             THEN 1
      WHEN REGEXP_CONTAINS(payment_terms, r'(?i)immediate|same\s*day')   THEN 1
      WHEN REGEXP_CONTAINS(payment_terms, r'(?i)(\d+)\s*day')
        THEN CAST(REGEXP_EXTRACT(payment_terms, r'(?i)(\d+)\s*day') AS INT64)
      ELSE 1
    END                                                  AS payment_terms_days,

    DATE_DIFF(invoice_date,  po_date,      DAY)          AS days_invoice_minus_po,
    DATE_DIFF(approval_date, po_date,      DAY)          AS days_approval_minus_po,
    DATE_DIFF(approval_date, invoice_date, DAY)          AS days_approval_minus_invoice

  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction`
  WHERE
    po_date           IS NOT NULL
    AND approval_date IS NOT NULL
    AND payment_amount IS NOT NULL
    AND payment_amount > 0
    AND invoice_date  >= '2024-01-01'  -- INVOICE_DATE_FLOOR: update when extending scoring window
    AND cost_centre   IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: Derived ratio features
-- Computed in a separate CTE so payment_terms_days is available.
-- SAFE_DIVIDE returns NULL on zero-denominators — no infinities produced.
-- Any resulting NULLs are handled by global median imputation in Step 6.
-- ─────────────────────────────────────────────────────────────────────────────
with_ratios AS (
  SELECT
    *,
    SAFE_DIVIDE(days_invoice_minus_po,       NULLIF(payment_terms_days, 0)) AS invoice_lag_to_terms_ratio,
    SAFE_DIVIDE(days_approval_minus_po,      NULLIF(payment_terms_days, 0)) AS approval_lag_po_to_terms_ratio,
    SAFE_DIVIDE(days_approval_minus_invoice, NULLIF(payment_terms_days, 0)) AS approval_lag_invoice_to_terms_ratio,
    SAFE_DIVIDE(payment_amount,              NULLIF(invoice_amount_excl_tax, 0)) AS payment_to_invoice_ratio,
    SAFE_DIVIDE(tax_amount,                  NULLIF(payment_amount, 0))          AS tax_to_payment_ratio
  FROM base
),

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: CC size filter
-- Exclude cost centres with fewer than 100 rows — too small for reliable
-- within-CC normalisation. Matches MIN_CC_SIZE = 100 in transaction_scorer.py.
-- ─────────────────────────────────────────────────────────────────────────────
scored_population AS (
  SELECT * EXCEPT (cc_row_count)
  FROM (
    SELECT
      *,
      COUNT(*) OVER (PARTITION BY cost_centre) AS cc_row_count
    FROM with_ratios
  )
  WHERE cc_row_count >= 100
),

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: Within-CC percentiles for the 5 CC-normalised features
-- Q1, median (Q2), and Q3 computed via PERCENTILE_CONT analytic function.
-- ─────────────────────────────────────────────────────────────────────────────
cc_percentiles AS (
  SELECT
    *,
    -- invoice_amount_excl_tax
    PERCENTILE_CONT(invoice_amount_excl_tax, 0.25) OVER (PARTITION BY cost_centre) AS cc_q1_invoice_amount,
    PERCENTILE_CONT(invoice_amount_excl_tax, 0.50) OVER (PARTITION BY cost_centre) AS cc_med_invoice_amount,
    PERCENTILE_CONT(invoice_amount_excl_tax, 0.75) OVER (PARTITION BY cost_centre) AS cc_q3_invoice_amount,
    -- payment_amount
    PERCENTILE_CONT(payment_amount, 0.25) OVER (PARTITION BY cost_centre)          AS cc_q1_payment_amount,
    PERCENTILE_CONT(payment_amount, 0.50) OVER (PARTITION BY cost_centre)          AS cc_med_payment_amount,
    PERCENTILE_CONT(payment_amount, 0.75) OVER (PARTITION BY cost_centre)          AS cc_q3_payment_amount,
    -- tax_amount
    PERCENTILE_CONT(tax_amount, 0.25) OVER (PARTITION BY cost_centre)              AS cc_q1_tax_amount,
    PERCENTILE_CONT(tax_amount, 0.50) OVER (PARTITION BY cost_centre)              AS cc_med_tax_amount,
    PERCENTILE_CONT(tax_amount, 0.75) OVER (PARTITION BY cost_centre)              AS cc_q3_tax_amount,
    -- invoice_lag_to_terms_ratio
    PERCENTILE_CONT(invoice_lag_to_terms_ratio, 0.25) OVER (PARTITION BY cost_centre) AS cc_q1_invoice_lag,
    PERCENTILE_CONT(invoice_lag_to_terms_ratio, 0.50) OVER (PARTITION BY cost_centre) AS cc_med_invoice_lag,
    PERCENTILE_CONT(invoice_lag_to_terms_ratio, 0.75) OVER (PARTITION BY cost_centre) AS cc_q3_invoice_lag,
    -- approval_lag_invoice_to_terms_ratio
    PERCENTILE_CONT(approval_lag_invoice_to_terms_ratio, 0.25) OVER (PARTITION BY cost_centre) AS cc_q1_approval_lag_inv,
    PERCENTILE_CONT(approval_lag_invoice_to_terms_ratio, 0.50) OVER (PARTITION BY cost_centre) AS cc_med_approval_lag_inv,
    PERCENTILE_CONT(approval_lag_invoice_to_terms_ratio, 0.75) OVER (PARTITION BY cost_centre) AS cc_q3_approval_lag_inv
  FROM scored_population
),

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: Within-CC normalisation → (value − median) / IQR
-- IQR = 0 (all values identical within CC) is treated as 1 to avoid NULLs —
-- matches Python: cc_stats.loc[cc_stats["iqr"] == 0, "iqr"] = 1
-- Integer features cast to FLOAT64 so all 12 columns share the same type.
-- ─────────────────────────────────────────────────────────────────────────────
cc_normalised AS (
  SELECT
    transaction_id,
    vendor_number,
    cost_centre,

    -- 5 CC-normalised features
    SAFE_DIVIDE(
      invoice_amount_excl_tax  - cc_med_invoice_amount,
      IF(cc_q3_invoice_amount  - cc_q1_invoice_amount  = 0, 1.0, cc_q3_invoice_amount  - cc_q1_invoice_amount)
    )                                                    AS invoice_amount_excl_tax_norm,

    SAFE_DIVIDE(
      payment_amount           - cc_med_payment_amount,
      IF(cc_q3_payment_amount  - cc_q1_payment_amount  = 0, 1.0, cc_q3_payment_amount  - cc_q1_payment_amount)
    )                                                    AS payment_amount_norm,

    SAFE_DIVIDE(
      tax_amount               - cc_med_tax_amount,
      IF(cc_q3_tax_amount      - cc_q1_tax_amount      = 0, 1.0, cc_q3_tax_amount      - cc_q1_tax_amount)
    )                                                    AS tax_amount_norm,

    SAFE_DIVIDE(
      invoice_lag_to_terms_ratio  - cc_med_invoice_lag,
      IF(cc_q3_invoice_lag        - cc_q1_invoice_lag  = 0, 1.0, cc_q3_invoice_lag     - cc_q1_invoice_lag)
    )                                                    AS invoice_lag_to_terms_ratio_norm,

    SAFE_DIVIDE(
      approval_lag_invoice_to_terms_ratio  - cc_med_approval_lag_inv,
      IF(cc_q3_approval_lag_inv            - cc_q1_approval_lag_inv = 0, 1.0, cc_q3_approval_lag_inv - cc_q1_approval_lag_inv)
    )                                                    AS approval_lag_invoice_to_terms_ratio_norm,

    -- 7 as-is features (cast to FLOAT64)
    CAST(payment_terms_days          AS FLOAT64)         AS payment_terms_days,
    CAST(days_invoice_minus_po       AS FLOAT64)         AS days_invoice_minus_po,
    CAST(days_approval_minus_po      AS FLOAT64)         AS days_approval_minus_po,
    CAST(days_approval_minus_invoice AS FLOAT64)         AS days_approval_minus_invoice,
    payment_to_invoice_ratio,
    approval_lag_po_to_terms_ratio,
    tax_to_payment_ratio

  FROM cc_percentiles
),

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6: Global median imputation
-- Any remaining NULLs (from SAFE_DIVIDE on zero-denominators) are replaced
-- with the global feature median. Matches Python: X.fillna(X.median()).
-- PERCENTILE_CONT OVER () computes the median across all rows.
-- ─────────────────────────────────────────────────────────────────────────────
global_medians AS (
  SELECT
    *,
    PERCENTILE_CONT(invoice_amount_excl_tax_norm,             0.5) OVER () AS gmed_invoice_amount_excl_tax_norm,
    PERCENTILE_CONT(payment_amount_norm,                       0.5) OVER () AS gmed_payment_amount_norm,
    PERCENTILE_CONT(tax_amount_norm,                           0.5) OVER () AS gmed_tax_amount_norm,
    PERCENTILE_CONT(invoice_lag_to_terms_ratio_norm,           0.5) OVER () AS gmed_invoice_lag_to_terms_ratio_norm,
    PERCENTILE_CONT(approval_lag_invoice_to_terms_ratio_norm,  0.5) OVER () AS gmed_approval_lag_invoice_to_terms_ratio_norm,
    PERCENTILE_CONT(payment_terms_days,                        0.5) OVER () AS gmed_payment_terms_days,
    PERCENTILE_CONT(days_invoice_minus_po,                     0.5) OVER () AS gmed_days_invoice_minus_po,
    PERCENTILE_CONT(days_approval_minus_po,                    0.5) OVER () AS gmed_days_approval_minus_po,
    PERCENTILE_CONT(days_approval_minus_invoice,               0.5) OVER () AS gmed_days_approval_minus_invoice,
    PERCENTILE_CONT(payment_to_invoice_ratio,                  0.5) OVER () AS gmed_payment_to_invoice_ratio,
    PERCENTILE_CONT(approval_lag_po_to_terms_ratio,            0.5) OVER () AS gmed_approval_lag_po_to_terms_ratio,
    PERCENTILE_CONT(tax_to_payment_ratio,                      0.5) OVER () AS gmed_tax_to_payment_ratio
  FROM cc_normalised
)

-- ─────────────────────────────────────────────────────────────────────────────
-- FINAL: Apply imputation — COALESCE replaces any remaining NULLs with the
-- global median. Output is a clean 12-feature matrix ready for IsolationForest.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  transaction_id,
  vendor_number,
  cost_centre,
  COALESCE(invoice_amount_excl_tax_norm,            gmed_invoice_amount_excl_tax_norm)            AS invoice_amount_excl_tax_norm,
  COALESCE(payment_amount_norm,                      gmed_payment_amount_norm)                      AS payment_amount_norm,
  COALESCE(tax_amount_norm,                          gmed_tax_amount_norm)                          AS tax_amount_norm,
  COALESCE(invoice_lag_to_terms_ratio_norm,          gmed_invoice_lag_to_terms_ratio_norm)          AS invoice_lag_to_terms_ratio_norm,
  COALESCE(approval_lag_invoice_to_terms_ratio_norm, gmed_approval_lag_invoice_to_terms_ratio_norm) AS approval_lag_invoice_to_terms_ratio_norm,
  COALESCE(payment_terms_days,                       gmed_payment_terms_days)                       AS payment_terms_days,
  COALESCE(days_invoice_minus_po,                    gmed_days_invoice_minus_po)                    AS days_invoice_minus_po,
  COALESCE(days_approval_minus_po,                   gmed_days_approval_minus_po)                   AS days_approval_minus_po,
  COALESCE(days_approval_minus_invoice,              gmed_days_approval_minus_invoice)              AS days_approval_minus_invoice,
  COALESCE(payment_to_invoice_ratio,                 gmed_payment_to_invoice_ratio)                 AS payment_to_invoice_ratio,
  COALESCE(approval_lag_po_to_terms_ratio,           gmed_approval_lag_po_to_terms_ratio)           AS approval_lag_po_to_terms_ratio,
  COALESCE(tax_to_payment_ratio,                     gmed_tax_to_payment_ratio)                     AS tax_to_payment_ratio
FROM global_medians
