-- =====================================================================
-- vendor_scores — single brief-input table per vendor
-- =====================================================================
--
-- PLACEHOLDER — anomaly scores are RAND() stubs until the Isolation
-- Forest model writes real scores to this table.
-- Do not use anomaly_score / anomaly_rank for production triage.
--
-- Extends vendor_features with:
--   (a) Anomaly score — STUB: RAND() until IF model is integrated
--   (b) Binary risk flags — pre-computed from base_transaction
--   (c) Top 10 transactions serialised as JSON
--   (d) Approval concentration serialised as JSON
--   (e) Payment terms breakdown serialised as JSON
--
-- This is the single table read by brief/builder.py.
-- All flag derivation and aggregation that was previously done in
-- Python is pushed here, keeping the brief service as JSON assembly only.
--
-- ANOMALY SCORE STUB [S1]:
--   anomaly_score = RAND() — replaced by Isolation Forest output (Track B Phase 2).
--   top_features  = NULL   — populated by IF model once available.
--   model_version = 'stub-random-v0'
--
-- TOP TRANSACTIONS [S2]:
--   Sorted by po_spend DESC until transaction_scores table is available.
--   Will switch to anomaly_score DESC once IF scores at transaction level.
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

    -- payment_within_7d_flag: >= 20% of transactions on N001 (7-day) terms
    SAFE_DIVIDE(
      COUNTIF(payment_terms LIKE '%N001%'),
      COUNT(*)
    ) >= 0.20                                                 AS payment_within_7d_flag,

    COUNTIF(payment_terms LIKE '%N001%')                     AS fast_payment_terms_count,
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
-- TOP 10 TRANSACTIONS — native ARRAY<STRUCT>
-- Sorted by po_spend DESC [S2] — will switch to anomaly_score once
-- transaction_scores is available.
-- ─────────────────────────────────────────────────────────────────────
ranked_txns AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY vendor_number ORDER BY po_spend DESC NULLS LAST) AS rn
  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction`
  WHERE vendor_number IS NOT NULL
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
        system
      )
      ORDER BY po_spend DESC NULLS LAST
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
-- RANDOM SCORES — stub until IF model writes to this table [S1]
-- anomaly_score: RAND() per vendor
-- anomaly_rank:  1 = most anomalous
-- ─────────────────────────────────────────────────────────────────────
random_scores AS (
  SELECT
    vendor_number,
    RAND()                                                    AS anomaly_score
  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.vendor_features`
)

-- ─────────────────────────────────────────────────────────────────────
-- FINAL ASSEMBLY
-- Inherits all vendor_features columns (raw features + peer comparisons)
-- and adds scoring, flags, and pre-serialised JSON fields.
-- ─────────────────────────────────────────────────────────────────────
SELECT
  -- Anomaly score [S1: replace with IF output]
  rs.anomaly_score,
  ROW_NUMBER() OVER (ORDER BY rs.anomaly_score DESC)          AS anomaly_rank,
  CAST(NULL AS STRING)                                        AS top_features,
  'stub-random-v0'                                            AS model_version,
  CURRENT_TIMESTAMP()                                          AS scored_at,

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
JOIN random_scores rs
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
