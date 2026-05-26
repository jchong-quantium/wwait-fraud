-- =====================================================================
-- vendor_features — vendor-level rollup of base_transaction
-- =====================================================================
--
-- Goal: produce gcp-wow-groupit-bizwear-dev.fraud.vendor_features
--       with one row per vendor_number, covering:
--         (a) raw features rolled up from base_transaction
--         (b) peer-comparison features (L2 supplier category)
--         (c) time-windowed versions: _3m, _6m, _12m, _24m
--             (24m = entire base_transaction history)
--
-- Design decisions confirmed 2026-05-19:
--   - Time anchor:   CURRENT_DATE('Australia/Sydney')
--   - Date column:   invoice_date drives the windows
--                    (matches dashboard convention; spend-centric)
--   - Vendor scope:  all vendors with at least one row in base_transaction
--   - NULL handling: vendor present in base_transaction but no rows in a
--                    given window → 0 (not NULL); never-seen vendors
--                    aren't in the table at all
--   - Peer groups:   L2 supplier category, all sizes (no min cutoff)
--   - vendor_attributes: joined to gcp-wow-groupit-bizwear-dev.fraud.vendor_attributes
--                        (real table — confirmed 2026-05-19)
--
-- Known caveat from base_transaction validation (parked):
--   po_spend is over-counted by ~27% when SUM'd over the table directly.
--   Mitigation here: dedupe to one row per (vendor, PO) using MAX(po_spend)
--   before summing. invoice_amount_excl_tax and payment_amount are safe
--   to sum directly because grain is (PO, invoice) — confirmed in Test 2.
-- =====================================================================

CREATE OR REPLACE TABLE `gcp-wow-groupit-bizwear-dev.fraud_dev.vendor_features`
AS

WITH

-- ─────────────────────────────────────────────────────────────────────
-- VENDOR ATTRIBUTES — joined from the canonical table.
-- One row per vendor with identity + category context for peer groups.
-- ─────────────────────────────────────────────────────────────────────
vendor_attributes AS (
  SELECT
    vendor_number,
    vendor_name,
    supplier_category_l1,
    supplier_category_l2,
    supplier_category_l3,
    country                                                AS supplier_country
  FROM `gcp-wow-groupit-bizwear-dev.fraud.vendor_attributes`
),

-- ─────────────────────────────────────────────────────────────────────
-- PO-LEVEL DEDUPE: collapse base_transaction to one row per (vendor, PO)
-- carrying MAX(po_spend). This is the workaround for the known
-- po_spend over-count in base_transaction. po_date is taken as MIN
-- because it's PO-level and identical across all rows of the same PO.
-- ─────────────────────────────────────────────────────────────────────
po_dedup AS (
  SELECT
    vendor_number,
    po_number,
    MIN(po_date)                                           AS po_date,
    MAX(po_spend)                                          AS po_spend
  FROM `gcp-wow-groupit-bizwear-dev.fraud.base_transaction`
  WHERE vendor_number IS NOT NULL
  GROUP BY vendor_number, po_number
),

-- ─────────────────────────────────────────────────────────────────────
-- BASE TRANSACTION rows tagged with the window flags up front. Computing
-- once means we don't repeat the date-diff math four times below.
-- ─────────────────────────────────────────────────────────────────────
bt_windowed AS (
  SELECT
    vendor_number,
    po_number,
    invoice_id,
    invoice_date,
    payment_date,
    invoice_amount_excl_tax,
    payment_amount,
    -- Window indicators (boolean: is this row in the _Xm window?)
    invoice_date >= DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 3 MONTH)  AS in_3m,
    invoice_date >= DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 6 MONTH)  AS in_6m,
    invoice_date >= DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 12 MONTH) AS in_12m,
    -- _24m is the entire base_transaction history; every row qualifies
    TRUE                                                                          AS in_24m
  FROM `gcp-wow-groupit-bizwear-dev.fraud.base_transaction`
  WHERE vendor_number IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────────────
-- Same windowing for the PO-deduped layer (po_spend feature only).
-- po_spend windowing uses po_date because we don't have invoice_date
-- at PO grain — and a "PO committed in last X months" is the cleaner
-- semantic for PO commitment anyway.
-- ─────────────────────────────────────────────────────────────────────
po_windowed AS (
  SELECT
    vendor_number,
    po_number,
    po_spend,
    po_date >= DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 3 MONTH)  AS in_3m,
    po_date >= DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 6 MONTH)  AS in_6m,
    po_date >= DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 12 MONTH) AS in_12m,
    TRUE                                                                     AS in_24m
  FROM po_dedup
),

-- ─────────────────────────────────────────────────────────────────────
-- RAW FEATURES per vendor per window
-- For each window, compute the 8 numeric features.
-- Aggregation rules:
--   - SUM on additive amounts (invoice, payment)
--   - SUM on PO spend (already deduped to one-row-per-PO in po_windowed)
--   - COUNT(DISTINCT) on identifiers
--   - vendor_active_months = distinct YYYY-MM of invoice_date in window
-- ─────────────────────────────────────────────────────────────────────
raw_invoice_features AS (
  SELECT
    vendor_number,
    -- _3m
    COALESCE(SUM(IF(in_3m,  invoice_amount_excl_tax, 0)), 0)         AS total_invoice_spend_3m,
    COALESCE(SUM(IF(in_3m,  payment_amount,           0)), 0)        AS total_payment_amount_3m,
    COUNT(DISTINCT IF(in_3m,  invoice_id, NULL))                     AS invoice_count_3m,
    COUNT(DISTINCT IF(in_3m AND payment_date IS NOT NULL, invoice_id, NULL))
                                                                      AS paid_invoice_count_3m,
    COUNT(DISTINCT IF(in_3m,  FORMAT_DATE('%Y-%m', invoice_date), NULL))
                                                                      AS vendor_active_months_3m,
    -- _6m
    COALESCE(SUM(IF(in_6m,  invoice_amount_excl_tax, 0)), 0)         AS total_invoice_spend_6m,
    COALESCE(SUM(IF(in_6m,  payment_amount,           0)), 0)        AS total_payment_amount_6m,
    COUNT(DISTINCT IF(in_6m,  invoice_id, NULL))                     AS invoice_count_6m,
    COUNT(DISTINCT IF(in_6m AND payment_date IS NOT NULL, invoice_id, NULL))
                                                                      AS paid_invoice_count_6m,
    COUNT(DISTINCT IF(in_6m,  FORMAT_DATE('%Y-%m', invoice_date), NULL))
                                                                      AS vendor_active_months_6m,
    -- _12m
    COALESCE(SUM(IF(in_12m, invoice_amount_excl_tax, 0)), 0)         AS total_invoice_spend_12m,
    COALESCE(SUM(IF(in_12m, payment_amount,           0)), 0)        AS total_payment_amount_12m,
    COUNT(DISTINCT IF(in_12m, invoice_id, NULL))                     AS invoice_count_12m,
    COUNT(DISTINCT IF(in_12m AND payment_date IS NOT NULL, invoice_id, NULL))
                                                                      AS paid_invoice_count_12m,
    COUNT(DISTINCT IF(in_12m, FORMAT_DATE('%Y-%m', invoice_date), NULL))
                                                                      AS vendor_active_months_12m,
    -- _24m (full window)
    COALESCE(SUM(invoice_amount_excl_tax), 0)                        AS total_invoice_spend_24m,
    COALESCE(SUM(payment_amount), 0)                                 AS total_payment_amount_24m,
    COUNT(DISTINCT invoice_id)                                       AS invoice_count_24m,
    COUNT(DISTINCT IF(payment_date IS NOT NULL, invoice_id, NULL))   AS paid_invoice_count_24m,
    COUNT(DISTINCT FORMAT_DATE('%Y-%m', invoice_date))               AS vendor_active_months_24m
  FROM bt_windowed
  GROUP BY vendor_number
),

raw_po_features AS (
  SELECT
    vendor_number,
    COALESCE(SUM(IF(in_3m,  po_spend, 0)), 0)              AS total_po_spend_3m,
    COUNT(DISTINCT IF(in_3m,  po_number, NULL))            AS po_count_3m,

    COALESCE(SUM(IF(in_6m,  po_spend, 0)), 0)              AS total_po_spend_6m,
    COUNT(DISTINCT IF(in_6m,  po_number, NULL))            AS po_count_6m,

    COALESCE(SUM(IF(in_12m, po_spend, 0)), 0)              AS total_po_spend_12m,
    COUNT(DISTINCT IF(in_12m, po_number, NULL))            AS po_count_12m,

    COALESCE(SUM(po_spend), 0)                             AS total_po_spend_24m,
    COUNT(DISTINCT po_number)                              AS po_count_24m
  FROM po_windowed
  GROUP BY vendor_number
),

-- ─────────────────────────────────────────────────────────────────────
-- VENDOR UNIVERSE — distinct vendors present in base_transaction.
-- (base_transaction has no vendor_name column; name comes from
-- vendor_attributes / SpendBase.)
-- ─────────────────────────────────────────────────────────────────────
vendor_universe AS (
  SELECT DISTINCT vendor_number
  FROM `gcp-wow-groupit-bizwear-dev.fraud.base_transaction`
  WHERE vendor_number IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────────────
-- RAW FEATURES JOINED: combine the two raw-feature CTEs + vendor identity
-- This is the "raw layer". Peer features are computed on top.
-- vendor_name sourced from vendor_attributes (SpendBase). If a vendor
-- exists in base_transaction but not in SpendBase, vendor_name will be
-- NULL — that's an in-scope data-quality concern to surface.
-- ─────────────────────────────────────────────────────────────────────
raw AS (
  SELECT
    vn.vendor_number,
    va.vendor_name                                         AS vendor_name,
    va.supplier_category_l1,
    va.supplier_category_l2,
    va.supplier_category_l3,
    va.supplier_country,

    -- PO features (8)
    COALESCE(rp.total_po_spend_3m,  0) AS total_po_spend_3m,
    COALESCE(rp.po_count_3m,        0) AS po_count_3m,
    COALESCE(rp.total_po_spend_6m,  0) AS total_po_spend_6m,
    COALESCE(rp.po_count_6m,        0) AS po_count_6m,
    COALESCE(rp.total_po_spend_12m, 0) AS total_po_spend_12m,
    COALESCE(rp.po_count_12m,       0) AS po_count_12m,
    COALESCE(rp.total_po_spend_24m, 0) AS total_po_spend_24m,
    COALESCE(rp.po_count_24m,       0) AS po_count_24m,

    -- Invoice + payment features (20)
    COALESCE(ri.total_invoice_spend_3m,    0) AS total_invoice_spend_3m,
    COALESCE(ri.total_payment_amount_3m,   0) AS total_payment_amount_3m,
    COALESCE(ri.invoice_count_3m,          0) AS invoice_count_3m,
    COALESCE(ri.paid_invoice_count_3m,     0) AS paid_invoice_count_3m,
    COALESCE(ri.vendor_active_months_3m,   0) AS vendor_active_months_3m,

    COALESCE(ri.total_invoice_spend_6m,    0) AS total_invoice_spend_6m,
    COALESCE(ri.total_payment_amount_6m,   0) AS total_payment_amount_6m,
    COALESCE(ri.invoice_count_6m,          0) AS invoice_count_6m,
    COALESCE(ri.paid_invoice_count_6m,     0) AS paid_invoice_count_6m,
    COALESCE(ri.vendor_active_months_6m,   0) AS vendor_active_months_6m,

    COALESCE(ri.total_invoice_spend_12m,   0) AS total_invoice_spend_12m,
    COALESCE(ri.total_payment_amount_12m,  0) AS total_payment_amount_12m,
    COALESCE(ri.invoice_count_12m,         0) AS invoice_count_12m,
    COALESCE(ri.paid_invoice_count_12m,    0) AS paid_invoice_count_12m,
    COALESCE(ri.vendor_active_months_12m,  0) AS vendor_active_months_12m,

    COALESCE(ri.total_invoice_spend_24m,   0) AS total_invoice_spend_24m,
    COALESCE(ri.total_payment_amount_24m,  0) AS total_payment_amount_24m,
    COALESCE(ri.invoice_count_24m,         0) AS invoice_count_24m,
    COALESCE(ri.paid_invoice_count_24m,    0) AS paid_invoice_count_24m,
    COALESCE(ri.vendor_active_months_24m,  0) AS vendor_active_months_24m
  FROM vendor_universe vn
  LEFT JOIN vendor_attributes va USING (vendor_number)
  LEFT JOIN raw_po_features rp   USING (vendor_number)
  LEFT JOIN raw_invoice_features ri USING (vendor_number)
)

-- ─────────────────────────────────────────────────────────────────────
-- FINAL OUTPUT: add peer-comparison features per L2 category × window
-- Peer features are computed using window functions partitioned by
-- supplier_category_l2. For vendors with no L2 (NULL), they form their
-- own peer group (PARTITION BY NULL groups them together).
--
-- Per feature, three peer columns:
--   peer_median_<feature>  = median within L2 category
--   peer_mean_<feature>    = mean within L2 category
--   peer_pct_rank_<feature> = percentile rank (0 to 1) within L2 category
-- ─────────────────────────────────────────────────────────────────────

SELECT
  vendor_number,
  vendor_name,
  supplier_category_l1,
  supplier_category_l2,
  supplier_category_l3,
  supplier_country,

  -- ─── PO features ───
  total_po_spend_3m,
  PERCENTILE_CONT(total_po_spend_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_po_spend_3m,
  AVG(total_po_spend_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_po_spend_3m,
  PERCENT_RANK()                          OVER (PARTITION BY supplier_category_l2 ORDER BY total_po_spend_3m) AS peer_pct_rank_total_po_spend_3m,

  po_count_3m,
  PERCENTILE_CONT(po_count_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_po_count_3m,
  AVG(po_count_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_po_count_3m,
  PERCENT_RANK()                    OVER (PARTITION BY supplier_category_l2 ORDER BY po_count_3m) AS peer_pct_rank_po_count_3m,

  total_po_spend_6m,
  PERCENTILE_CONT(total_po_spend_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_po_spend_6m,
  AVG(total_po_spend_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_po_spend_6m,
  PERCENT_RANK()                          OVER (PARTITION BY supplier_category_l2 ORDER BY total_po_spend_6m) AS peer_pct_rank_total_po_spend_6m,

  po_count_6m,
  PERCENTILE_CONT(po_count_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_po_count_6m,
  AVG(po_count_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_po_count_6m,
  PERCENT_RANK()                    OVER (PARTITION BY supplier_category_l2 ORDER BY po_count_6m) AS peer_pct_rank_po_count_6m,

  total_po_spend_12m,
  PERCENTILE_CONT(total_po_spend_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_po_spend_12m,
  AVG(total_po_spend_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_po_spend_12m,
  PERCENT_RANK()                           OVER (PARTITION BY supplier_category_l2 ORDER BY total_po_spend_12m) AS peer_pct_rank_total_po_spend_12m,

  po_count_12m,
  PERCENTILE_CONT(po_count_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_po_count_12m,
  AVG(po_count_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_po_count_12m,
  PERCENT_RANK()                     OVER (PARTITION BY supplier_category_l2 ORDER BY po_count_12m) AS peer_pct_rank_po_count_12m,

  total_po_spend_24m,
  PERCENTILE_CONT(total_po_spend_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_po_spend_24m,
  AVG(total_po_spend_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_po_spend_24m,
  PERCENT_RANK()                           OVER (PARTITION BY supplier_category_l2 ORDER BY total_po_spend_24m) AS peer_pct_rank_total_po_spend_24m,

  po_count_24m,
  PERCENTILE_CONT(po_count_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_po_count_24m,
  AVG(po_count_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_po_count_24m,
  PERCENT_RANK()                     OVER (PARTITION BY supplier_category_l2 ORDER BY po_count_24m) AS peer_pct_rank_po_count_24m,

  -- ─── Invoice features ───
  total_invoice_spend_3m,
  PERCENTILE_CONT(total_invoice_spend_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_invoice_spend_3m,
  AVG(total_invoice_spend_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_invoice_spend_3m,
  PERCENT_RANK()                               OVER (PARTITION BY supplier_category_l2 ORDER BY total_invoice_spend_3m) AS peer_pct_rank_total_invoice_spend_3m,

  invoice_count_3m,
  PERCENTILE_CONT(invoice_count_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_invoice_count_3m,
  AVG(invoice_count_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_invoice_count_3m,
  PERCENT_RANK()                         OVER (PARTITION BY supplier_category_l2 ORDER BY invoice_count_3m) AS peer_pct_rank_invoice_count_3m,

  total_invoice_spend_6m,
  PERCENTILE_CONT(total_invoice_spend_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_invoice_spend_6m,
  AVG(total_invoice_spend_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_invoice_spend_6m,
  PERCENT_RANK()                               OVER (PARTITION BY supplier_category_l2 ORDER BY total_invoice_spend_6m) AS peer_pct_rank_total_invoice_spend_6m,

  invoice_count_6m,
  PERCENTILE_CONT(invoice_count_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_invoice_count_6m,
  AVG(invoice_count_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_invoice_count_6m,
  PERCENT_RANK()                         OVER (PARTITION BY supplier_category_l2 ORDER BY invoice_count_6m) AS peer_pct_rank_invoice_count_6m,

  total_invoice_spend_12m,
  PERCENTILE_CONT(total_invoice_spend_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_invoice_spend_12m,
  AVG(total_invoice_spend_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_invoice_spend_12m,
  PERCENT_RANK()                                OVER (PARTITION BY supplier_category_l2 ORDER BY total_invoice_spend_12m) AS peer_pct_rank_total_invoice_spend_12m,

  invoice_count_12m,
  PERCENTILE_CONT(invoice_count_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_invoice_count_12m,
  AVG(invoice_count_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_invoice_count_12m,
  PERCENT_RANK()                          OVER (PARTITION BY supplier_category_l2 ORDER BY invoice_count_12m) AS peer_pct_rank_invoice_count_12m,

  total_invoice_spend_24m,
  PERCENTILE_CONT(total_invoice_spend_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_invoice_spend_24m,
  AVG(total_invoice_spend_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_invoice_spend_24m,
  PERCENT_RANK()                                OVER (PARTITION BY supplier_category_l2 ORDER BY total_invoice_spend_24m) AS peer_pct_rank_total_invoice_spend_24m,

  invoice_count_24m,
  PERCENTILE_CONT(invoice_count_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_invoice_count_24m,
  AVG(invoice_count_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_invoice_count_24m,
  PERCENT_RANK()                          OVER (PARTITION BY supplier_category_l2 ORDER BY invoice_count_24m) AS peer_pct_rank_invoice_count_24m,

  -- ─── Payment features ───
  total_payment_amount_3m,
  PERCENTILE_CONT(total_payment_amount_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_payment_amount_3m,
  AVG(total_payment_amount_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_payment_amount_3m,
  PERCENT_RANK()                                OVER (PARTITION BY supplier_category_l2 ORDER BY total_payment_amount_3m) AS peer_pct_rank_total_payment_amount_3m,

  paid_invoice_count_3m,
  PERCENTILE_CONT(paid_invoice_count_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_paid_invoice_count_3m,
  AVG(paid_invoice_count_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_paid_invoice_count_3m,
  PERCENT_RANK()                              OVER (PARTITION BY supplier_category_l2 ORDER BY paid_invoice_count_3m) AS peer_pct_rank_paid_invoice_count_3m,

  total_payment_amount_6m,
  PERCENTILE_CONT(total_payment_amount_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_payment_amount_6m,
  AVG(total_payment_amount_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_payment_amount_6m,
  PERCENT_RANK()                                OVER (PARTITION BY supplier_category_l2 ORDER BY total_payment_amount_6m) AS peer_pct_rank_total_payment_amount_6m,

  paid_invoice_count_6m,
  PERCENTILE_CONT(paid_invoice_count_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_paid_invoice_count_6m,
  AVG(paid_invoice_count_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_paid_invoice_count_6m,
  PERCENT_RANK()                              OVER (PARTITION BY supplier_category_l2 ORDER BY paid_invoice_count_6m) AS peer_pct_rank_paid_invoice_count_6m,

  total_payment_amount_12m,
  PERCENTILE_CONT(total_payment_amount_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_payment_amount_12m,
  AVG(total_payment_amount_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_payment_amount_12m,
  PERCENT_RANK()                                 OVER (PARTITION BY supplier_category_l2 ORDER BY total_payment_amount_12m) AS peer_pct_rank_total_payment_amount_12m,

  paid_invoice_count_12m,
  PERCENTILE_CONT(paid_invoice_count_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_paid_invoice_count_12m,
  AVG(paid_invoice_count_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_paid_invoice_count_12m,
  PERCENT_RANK()                               OVER (PARTITION BY supplier_category_l2 ORDER BY paid_invoice_count_12m) AS peer_pct_rank_paid_invoice_count_12m,

  total_payment_amount_24m,
  PERCENTILE_CONT(total_payment_amount_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_total_payment_amount_24m,
  AVG(total_payment_amount_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_total_payment_amount_24m,
  PERCENT_RANK()                                 OVER (PARTITION BY supplier_category_l2 ORDER BY total_payment_amount_24m) AS peer_pct_rank_total_payment_amount_24m,

  paid_invoice_count_24m,
  PERCENTILE_CONT(paid_invoice_count_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_paid_invoice_count_24m,
  AVG(paid_invoice_count_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_paid_invoice_count_24m,
  PERCENT_RANK()                               OVER (PARTITION BY supplier_category_l2 ORDER BY paid_invoice_count_24m) AS peer_pct_rank_paid_invoice_count_24m,

  -- ─── Activity features ───
  vendor_active_months_3m,
  PERCENTILE_CONT(vendor_active_months_3m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_vendor_active_months_3m,
  AVG(vendor_active_months_3m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_vendor_active_months_3m,
  PERCENT_RANK()                                OVER (PARTITION BY supplier_category_l2 ORDER BY vendor_active_months_3m) AS peer_pct_rank_vendor_active_months_3m,

  vendor_active_months_6m,
  PERCENTILE_CONT(vendor_active_months_6m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_vendor_active_months_6m,
  AVG(vendor_active_months_6m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_vendor_active_months_6m,
  PERCENT_RANK()                                OVER (PARTITION BY supplier_category_l2 ORDER BY vendor_active_months_6m) AS peer_pct_rank_vendor_active_months_6m,

  vendor_active_months_12m,
  PERCENTILE_CONT(vendor_active_months_12m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_vendor_active_months_12m,
  AVG(vendor_active_months_12m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_vendor_active_months_12m,
  PERCENT_RANK()                                 OVER (PARTITION BY supplier_category_l2 ORDER BY vendor_active_months_12m) AS peer_pct_rank_vendor_active_months_12m,

  vendor_active_months_24m,
  PERCENTILE_CONT(vendor_active_months_24m, 0.5) OVER (PARTITION BY supplier_category_l2)  AS peer_median_vendor_active_months_24m,
  AVG(vendor_active_months_24m)                  OVER (PARTITION BY supplier_category_l2)  AS peer_mean_vendor_active_months_24m,
  PERCENT_RANK()                                 OVER (PARTITION BY supplier_category_l2 ORDER BY vendor_active_months_24m) AS peer_pct_rank_vendor_active_months_24m,

  -- ─── Peer-group size for QC (so consumers know if peer stats are reliable) ───
  COUNT(*) OVER (PARTITION BY supplier_category_l2)         AS peer_group_size,

  -- ─── Metadata ───
  CURRENT_TIMESTAMP()                                       AS _loaded_at

FROM raw;
