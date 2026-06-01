-- =====================================================================
-- vendor_scores — single brief-input table per vendor
-- =====================================================================
--
-- Extends vendor_features with:
--   (a) Anomaly score — rolled up from transaction_scores (IF model)
--   (b) Binary risk flags — pre-computed from base_transaction
--   (c) Top 10 transactions serialised as JSON, sorted by anomaly_score
--   (d) Approval concentration serialised as JSON
--   (e) Payment terms breakdown serialised as JSON
--
-- This is the single table read by brief/builder.py.
-- All flag derivation and aggregation that was previously done in
-- Python is pushed here, keeping the brief service as JSON assembly only.
--
-- ANOMALY SCORE ROLLUP:
--   anomaly_rate  = % of vendor's transactions flagged as anomalous (primary)
--   anomaly_score = same as anomaly_rate (used for ranking)
--   anomaly_rank  = 1 = highest anomaly_rate
--   top_features  = most frequent SHAP top driver across vendor's anomalies
--   model_version = scorer version from transaction_scores
--
-- TOP TRANSACTIONS [S2]:
--   Sorted by anomaly_score DESC from transaction_scores.
--   Transactions not scored (filtered out by scorer) retain NULL anomaly_score
--   and sort last.
--
-- BINARY FLAGS — NULL SEMANTICS:
--   NULL  = underlying data not collected / check cannot be performed
--   FALSE = data available, checked, result is negative
--   TRUE  = data available, checked, flag raised
--
-- OUTSTANDING DATA GAPS (inherited from base_transaction):
--   employee_bank_match — pending dim_lfbk_vendor_bank_details_v [D1]
--   doa_breach_flag     — pending audit_group_enablement.doa [D2]
--   collusion_indicator — requires employee_bank_match [D1]
--
-- REFRESH:
--   After vendor_features — run as the final pipeline step.
-- =====================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.vendor_scores`
AS

WITH

-- ─────────────────────────────────────────────────────────────────────
-- BINARY FLAGS — replaces Python-side derivation in build_binary_flags
-- ─────────────────────────────────────────────────────────────────────
flags AS (
  SELECT
    vendor_number,
    MIN(invoice_date)                                          AS data_window_start,
    MAX(invoice_date)                                         AS data_window_end,
    COUNT(*)                                                  AS total_transaction_count,

    -- blocked_payment_flag: any transaction with a known adverse status
    COUNTIF(
      reconciliation_status IN ('Rejected', 'Paying Failed', 'Canceled')
      OR po_status IN ('Rejected')
    ) > 0                                                     AS blocked_payment_flag,

    -- payment_within_7d_flag: >= 20% of transactions on fast terms (<= 7 days)
    -- Covers: N001 (7d), N011 (5d), N03D (3d), N005 (immediate)
    SAFE_DIVIDE(
      COUNTIF(
        payment_terms LIKE '%N001%'
        OR payment_terms LIKE '%N011%'
        OR payment_terms LIKE '%N03D%'
        OR payment_terms LIKE '%N005%'
      ),
      COUNT(*)
    ) >= 0.20                                                 AS payment_within_7d_flag,

    COUNTIF(
      payment_terms LIKE '%N001%'
      OR payment_terms LIKE '%N011%'
      OR payment_terms LIKE '%N03D%'
      OR payment_terms LIKE '%N005%'
    )                                                         AS fast_payment_terms_count,
    COUNTIF(acted_on_behalf_of = TRUE)                       AS acted_on_behalf_of_count,

    COUNTIF(invoice_status IN ('Rejected', 'Canceled'))      AS rejected_invoices_count,
    COUNTIF(po_status IN ('Rejected'))                       AS rejected_po_count

  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction`
  WHERE vendor_number IS NOT NULL
  GROUP BY vendor_number
),

-- ─────────────────────────────────────────────────────────────────────
-- APPROVAL CONCENTRATION — share per approver as ARRAY<STRUCT>
-- [{approver, share}, ...] ordered by share DESC
-- ─────────────────────────────────────────────────────────────────────
approval_concentration AS (
  SELECT
    vendor_number,
    ARRAY_AGG(
      STRUCT(approved_by_user AS approver, ROUND(SAFE_DIVIDE(cnt, total), 4) AS share)
      ORDER BY cnt DESC
    )                                                         AS approval_concentration
  FROM (
    SELECT
      vendor_number,
      approved_by_user,
      COUNT(*)                                               AS cnt,
      SUM(COUNT(*)) OVER (PARTITION BY vendor_number)       AS total
    FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction`
    WHERE vendor_number IS NOT NULL
      AND approved_by_user IS NOT NULL
    GROUP BY vendor_number, approved_by_user
  )
  GROUP BY vendor_number
),

-- ─────────────────────────────────────────────────────────────────────
-- PAYMENT TERMS BREAKDOWN — count per terms code as ARRAY<STRUCT>
-- [{terms, count}, ...] ordered by count DESC
-- ─────────────────────────────────────────────────────────────────────
terms_breakdown AS (
  SELECT
    vendor_number,
    ARRAY_AGG(
      STRUCT(payment_terms AS terms, cnt AS count)
      ORDER BY cnt DESC
    )                                                         AS payment_terms_breakdown
  FROM (
    SELECT vendor_number, payment_terms, COUNT(*) AS cnt
    FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction`
    WHERE vendor_number IS NOT NULL
      AND payment_terms IS NOT NULL
    GROUP BY vendor_number, payment_terms
  )
  GROUP BY vendor_number
),

-- ─────────────────────────────────────────────────────────────────────
-- TOP 10 TRANSACTIONS — sorted by anomaly_score DESC from transaction_scores.
-- Unscored transactions (filtered out by scorer) sort last via NULLS LAST.
-- ─────────────────────────────────────────────────────────────────────
ranked_txns AS (
  SELECT
    bt.*,
    ts.anomaly_score                                          AS txn_anomaly_score,
    ts.top_driver_feature,
    ROW_NUMBER() OVER (
      PARTITION BY bt.vendor_number
      ORDER BY ts.anomaly_score DESC NULLS LAST
    )                                                         AS rn
  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction` bt
  LEFT JOIN `${GCP_PROJECT_ID}.${BQ_DATASET}.transaction_scores` ts
    USING (transaction_id)
  WHERE bt.vendor_number IS NOT NULL
),

top_transactions AS (
  SELECT
    vendor_number,
    ARRAY_AGG(
      STRUCT(
        transaction_id,
        po_number,
        po_date,
        invoice_date,
        invoice_id,
        po_spend,
        invoice_amount_excl_tax,
        payment_amount,
        approved_by_user,
        nominated_approver,
        acted_on_behalf_of,
        requestor,
        po_status,
        invoice_status,
        reconciliation_status,
        payment_terms,
        system,
        txn_anomaly_score,
        top_driver_feature
      )
      ORDER BY txn_anomaly_score DESC NULLS LAST
    )                                                         AS top_transactions
  FROM ranked_txns
  WHERE rn <= 10
  GROUP BY vendor_number
),

-- ─────────────────────────────────────────────────────────────────────
-- VENDOR ATTRIBUTES — additional fields not in vendor_features
-- ─────────────────────────────────────────────────────────────────────
va AS (
  SELECT
    vendor_number,
    vendor_creation_date,
    vendor_status,
    local_supplier_flag,
    vendor_abn,
    supplier_id,
    vendor_bank_bsb,
    vendor_bank_account
  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.vendor_attributes`
),

-- ─────────────────────────────────────────────────────────────────────
-- VENDOR ANOMALY SCORES — rolled up from transaction_scores
-- anomaly_rate  = % of transactions flagged (primary ranking metric)
-- top_features  = most frequent SHAP top driver across vendor's anomalies
-- ─────────────────────────────────────────────────────────────────────
vendor_anomaly AS (
  SELECT
    vendor_number,
    COUNTIF(is_anomaly) / COUNT(*)                           AS anomaly_rate,
    MAX(anomaly_score)                                       AS anomaly_score_max,
    AVG(anomaly_score)                                       AS anomaly_score_mean,
    COUNTIF(is_anomaly)                                      AS anomaly_txn_count,
    COUNT(*)                                                 AS scored_txn_count,
    -- Most frequent SHAP top driver across this vendor's anomalous transactions
    (
      SELECT top_driver_feature
      FROM UNNEST(ARRAY_AGG(
        IF(is_anomaly AND top_driver_feature IS NOT NULL, top_driver_feature, NULL)
        IGNORE NULLS
      ))
      GROUP BY top_driver_feature
      ORDER BY COUNT(*) DESC
      LIMIT 1
    )                                                        AS top_features,
    ANY_VALUE(model_version)                                 AS model_version,
    MAX(scored_at)                                           AS scored_at
  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.transaction_scores`
  GROUP BY vendor_number
)

-- ─────────────────────────────────────────────────────────────────────
-- FINAL ASSEMBLY
-- Inherits all vendor_features columns (raw features + peer comparisons)
-- and adds scoring, flags, and pre-serialised JSON fields.
-- ─────────────────────────────────────────────────────────────────────
SELECT
  -- Anomaly scores rolled up from transaction_scores
  va.anomaly_rate                                             AS anomaly_score,
  ROW_NUMBER() OVER (ORDER BY va.anomaly_rate DESC)           AS anomaly_rank,
  va.anomaly_score_max,
  va.anomaly_score_mean,
  va.anomaly_txn_count,
  va.scored_txn_count,
  va.top_features,
  va.model_version,
  va.scored_at,

  --  All vendor_features columns (raw features + peer comparisons)
  vf.*,

  -- Vendor attributes not in vendor_features 
  va.vendor_creation_date,
  va.vendor_status,
  va.local_supplier_flag,
  va.vendor_abn,
  va.supplier_id,
  va.vendor_bank_bsb,
  va.vendor_bank_account,

  -- Binary flags 
  CAST(NULL AS BOOL)                                         AS employee_bank_match,
  CAST(NULL AS STRING)                                       AS matched_employee_name,
  CAST(NULL AS STRING)                                       AS matched_employee_job_title,
  CAST(NULL AS BOOL)                                         AS doa_breach_flag,
  f.blocked_payment_flag,
  f.payment_within_7d_flag,
  CAST(NULL AS BOOL)                                         AS collusion_indicator,

  -- Flag details
  f.fast_payment_terms_count,
  f.acted_on_behalf_of_count,
  f.rejected_invoices_count,
  f.rejected_po_count,
  ac.approval_concentration,
  tb.payment_terms_breakdown,

  -- Transaction summary
  f.total_transaction_count,
  f.data_window_start,
  f.data_window_end,
  tt.top_transactions

FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.vendor_features` vf
JOIN vendor_anomaly va
  USING (vendor_number)
LEFT JOIN va
  USING (vendor_number)
LEFT JOIN flags f
  USING (vendor_number)
LEFT JOIN approval_concentration ac
  USING (vendor_number)
LEFT JOIN terms_breakdown tb
  USING (vendor_number)
LEFT JOIN top_transactions tt
  USING (vendor_number)
