-- =============================================================================
-- Fraud Analytics — combined transaction table (Ariba + SAP payments)
--
-- WHAT THIS TABLE IS
--   One enriched row per Ariba INVOICE LINE for calendar 2024 onwards. Each row
--   stitches together the full procurement story for that line:
--     Approval chain  →  Purchase Order (commitment)  →  Invoice (billed)
--                                                      →  SAP (paid)
--   plus vendor status and delegation-of-authority (DOA) limits.
--
-- GRAIN — invoice line
--   The base grain is the invoice line, so line-level detail (where most fraud
--   signals live) is preserved. The PO is linked at HEADER level only:
--     - For goods, a PO line maps 1:1 to an invoice line.
--     - For services, one PO line is billed across many invoices over time.
--     - For high-volume items, the same line repeats many times on both sides.
--   Because there is no reliable PO-line-to-invoice-line key for services and
--   high-volume cases, joining at that level would either drop rows or multiply
--   them. So PO attributes (commitment, vendor, approver) attach at PO level,
--   and the invoice line stays the unit of analysis.
--
-- GST
--   ~44% of source rows are standalone "AU GST" / "NZ GST" rows. These are
--   filtered out; the goods/services line carries its own tax amount, and the
--   table exposes ex-tax, GST, and incl-tax amounts separately.
--
-- SAP PAYMENTS — ~66% coverage
--   SAP postings are linked to Ariba invoices via the invoice number, then
--   aggregated to one SAP total per invoice (SAP postings do not line up to
--   individual Ariba lines, but the SAP total reconciles to the Ariba invoice
--   total on an ex-tax basis). ~66% of invoice lines find a SAP payment; the
--   rest are unpaid, not-yet-posted, or have no SAP reference. Where there is
--   no match the SAP/payment columns are NULL — NULL means "not matched in
--   SAP", NOT "not paid". The sap_match column flags which is which.
--
-- BLOCKED VENDORS
--   Vendor status is sourced from the vendor master. Status 'A' = active;
--   anything else is treated as blocked. flag_blocked_vendor_active surfaces
--   lines billed to non-active vendors as a rule-based check.
--
-- DELEGATION OF AUTHORITY (DOA)
--   Each approver's annual authority limit is attached per step in the chain,
--   with flags for POs committed above every approver's limit. The DOA join is
--   name-based, so coverage depends on name consistency between systems.
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction_line_sap`
AS

WITH

-- INVOICE LINES — base grain. Standalone GST rows removed; ex-tax / GST /
-- incl-tax amounts exposed; payment-terms day-count parsed from the raw terms.
invoice_lines AS (
  SELECT
    invoice_id,
    order_id                              AS po_number,
    description                           AS line_description,
    amount_invoiced                       AS billed_amount_ex_tax,
    Tax_Amount_AUD                        AS gst_amount,
    Paid_Amount_in_Original_Currency      AS paid_amount_orig_ccy,
    invoice_date,
    invoice_created_date,
    paid_date,
    invoice_status,
    reconciliation_status,
    payment_terms,
    -- payment_terms_days: parse a day-count from the free-text terms
    -- (e.g. "30 days" -> 30, "immediately" -> 0).
    CASE
      WHEN payment_terms IS NULL OR TRIM(payment_terms) = '' THEN NULL
      WHEN LOWER(payment_terms) LIKE '%immediately%'         THEN 0
      ELSE SAFE_CAST(
        REGEXP_EXTRACT(LOWER(payment_terms), r'(\d+)\s*day') AS INT64
      )
    END                                   AS payment_terms_days,
    cost_center_id                        AS cost_centre,
    cost_center_name                      AS cost_centre_name,
    supplier_erp_supplier                 AS vendor_raw,
    -- within-invoice sequence number, so each line has a unique key even when a
    -- description+amount repeats on the same invoice.
    ROW_NUMBER() OVER (
      PARTITION BY invoice_id
      ORDER BY description, amount_invoiced, cost_center_id,
               invoice_created_date, order_id
    )                                     AS line_seq
  FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_POandInvoices_v`
  WHERE invoice_date >= DATE '2024-01-01'
    AND order_id IS NOT NULL
    AND order_id <> 'Unclassified'
    AND UPPER(TRIM(description)) NOT IN ('AU GST', 'NZ GST')
),

-- PO HEADER — PO line-level source aggregated to one row per PO. Carries the
-- commitment total, vendor, requester, and the approvable id (link to approvals).
po_header AS (
  SELECT
    po_order_id,
    ANY_VALUE(aps_req_approvable_id)                       AS approvable_id,
    ANY_VALUE(req_requisition_id)                          AS req_requisition_id,
    ANY_VALUE(requester_user)                              AS requester_user,
    ANY_VALUE(supplier_erp_id)                             AS vendor_number,
    ANY_VALUE(supplier_erp_name)                           AS vendor_name,
    MIN(CAST(ordered_date AS DATE))                        AS po_date,
    ANY_VALUE(po_status)                                   AS po_status,
    ANY_VALUE(contract_id)                                 AS contract_id,
    ANY_VALUE(payment_terms)                               AS po_payment_terms,
    COUNT(*)                                               AS po_line_count,
    CAST(SUM(sum_po_spend) AS FLOAT64)                     AS po_total_committed,
    CAST(SUM(sum_requisition_spend) AS FLOAT64)            AS po_total_requisition
  FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_PO_Linelevel_v`
  GROUP BY po_order_id
),

-- APPROVALS — one row per approval step, ordered into a chain per approvable.
-- nominee = who the step was assigned to; actor = who actually approved.
approvals_ranked AS (
  SELECT
    Approvable_ID,
    Approver                                              AS nominee,
    Real_User                                             AS actor,
    CAST(Action_Date AS DATE)                             AS action_date,
    ROW_NUMBER() OVER (
      PARTITION BY Approvable_ID ORDER BY Action_Date ASC
    )                                                      AS rank_asc
  FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_Approvals_v`
  WHERE Approver_State = 'Approved'
    AND Real_User IS NOT NULL
    AND Real_User <> ''
),

-- Pivot the chain into up to 7 approval levels + chain length + final approver.
approvals_pivoted AS (
  SELECT
    Approvable_ID,
    COUNT(*)                                              AS chain_length,
    MIN(action_date)                                      AS first_approval_date,
    MAX(action_date)                                      AS final_approval_date,
    MAX(IF(rank_asc = 1, nominee, NULL))                  AS app_1_nominee,
    MAX(IF(rank_asc = 1, actor,   NULL))                  AS app_1_actor,
    MAX(IF(rank_asc = 1, action_date, NULL))              AS app_1_date,
    MAX(IF(rank_asc = 2, nominee, NULL))                  AS app_2_nominee,
    MAX(IF(rank_asc = 2, actor,   NULL))                  AS app_2_actor,
    MAX(IF(rank_asc = 2, action_date, NULL))              AS app_2_date,
    MAX(IF(rank_asc = 3, nominee, NULL))                  AS app_3_nominee,
    MAX(IF(rank_asc = 3, actor,   NULL))                  AS app_3_actor,
    MAX(IF(rank_asc = 3, action_date, NULL))              AS app_3_date,
    MAX(IF(rank_asc = 4, nominee, NULL))                  AS app_4_nominee,
    MAX(IF(rank_asc = 4, actor,   NULL))                  AS app_4_actor,
    MAX(IF(rank_asc = 4, action_date, NULL))              AS app_4_date,
    MAX(IF(rank_asc = 5, nominee, NULL))                  AS app_5_nominee,
    MAX(IF(rank_asc = 5, actor,   NULL))                  AS app_5_actor,
    MAX(IF(rank_asc = 5, action_date, NULL))              AS app_5_date,
    MAX(IF(rank_asc = 6, nominee, NULL))                  AS app_6_nominee,
    MAX(IF(rank_asc = 6, actor,   NULL))                  AS app_6_actor,
    MAX(IF(rank_asc = 6, action_date, NULL))              AS app_6_date,
    MAX(IF(rank_asc = 7, nominee, NULL))                  AS app_7_nominee,
    MAX(IF(rank_asc = 7, actor,   NULL))                  AS app_7_actor,
    MAX(IF(rank_asc = 7, action_date, NULL))              AS app_7_date,
    MAX(IF(rank_asc = chain_length_calc, actor, NULL))    AS final_actor
  FROM (
    SELECT *, MAX(rank_asc) OVER (PARTITION BY Approvable_ID) AS chain_length_calc
    FROM approvals_ranked
  )
  GROUP BY Approvable_ID
),

-- Per-PO billed totals — for the over-billing (billed vs committed) signal.
invoice_totals_per_po AS (
  SELECT
    po_number,
    SUM(billed_amount_ex_tax)                             AS total_billed_against_po,
    COUNT(*)                                              AS invoice_line_count_on_po,
    COUNT(DISTINCT invoice_id)                            AS invoice_count_on_po,
    COUNTIF(invoice_status = 'Rejected')                  AS rejected_line_count_on_po
  FROM invoice_lines
  GROUP BY po_number
),

-- Per-invoice billed total (ex-tax). SAP payment is at invoice grain, so the
-- payment-reconciliation ratios compare the SAP total to the INVOICE total
-- (not to a single line, which would be wrong for multi-line invoices).
invoice_totals AS (
  SELECT
    invoice_id,
    SUM(billed_amount_ex_tax)                             AS invoice_billed_ex_tax,
    SUM(gst_amount)                                       AS invoice_gst
  FROM invoice_lines
  GROUP BY invoice_id
),

-- SAP PAYMENTS — linked at INVOICE level via the invoice number, aggregated to
-- one SAP total per invoice. payment_amount is the invoice's total SAP payment
-- and is the SAME on every line of that invoice — it should not be summed across
-- lines downstream. Only ~66% of invoices match; the rest are NULL (not matched).
sap_payments AS (
  SELECT
    UPPER(TRIM(Invoice_Number))                           AS k_invoice,
    SUM(CAST(Amount AS FLOAT64))                          AS sap_posted_amount,
    MIN(Posting_Date)                                     AS sap_posting_date,
    ANY_VALUE(Transaction)                                AS sap_payment_type,
    ANY_VALUE(Vendor_ID)                                  AS sap_vendor_id,
    COUNT(*)                                              AS sap_posting_count
  FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v`
  WHERE Invoice_Number IS NOT NULL
    AND Posting_Date >= DATE '2024-01-01'
  GROUP BY k_invoice
),

-- VENDOR STATUS — from the vendor master. 'A' = active; anything else = blocked.
-- Keyed on vendor number; deduped to one row per vendor.
vendor_status_lookup AS (
  SELECT
    UPPER(TRIM(Vendor))        AS vendor_number,
    ANY_VALUE(VendorStatus)    AS vendor_status
  FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v`
  WHERE Vendor IS NOT NULL
  GROUP BY UPPER(TRIM(Vendor))
),

-- DOA — annual authority limit per person, name-keyed and deduped (only names
-- with a single unambiguous limit are kept).
doa_unique AS (
  SELECT
    UPPER(TRIM(Employee_Name))                                       AS approver_upper,
    MAX(CAST(General_Authority_Limits___Annual_Limit__ AS FLOAT64)) AS doa_annual_limit
  FROM `gcp-wow-risk-de-lab-dev.audit_group_enablement.doa`
  WHERE Employee_Name IS NOT NULL AND TRIM(Employee_Name) <> ''
  GROUP BY UPPER(TRIM(Employee_Name))
  HAVING COUNT(*) = 1
)

SELECT
  CONCAT(
    COALESCE(il.invoice_id, 'NULL'), '|',
    COALESCE(il.po_number, 'NULL'), '|',
    CAST(il.line_seq AS STRING)
  )                                                       AS transaction_line_id,
  'Ariba'                                                 AS system,

  -- ── invoice-line identity & money ──
  il.invoice_id,
  il.line_seq,
  il.po_number,
  il.line_description,
  il.billed_amount_ex_tax,
  il.gst_amount,
  il.invoice_date,
  il.paid_date,
  il.invoice_status,
  il.reconciliation_status,
  il.payment_terms,
  il.cost_centre,
  il.cost_centre_name,

  -- ── PO header attributes ──
  ph.po_date,
  ph.po_status,
  ph.vendor_number,
  ph.vendor_name,
  ph.requester_user,
  ph.contract_id,
  ph.po_line_count,
  ph.po_total_committed,

  -- ── over-billing signal (billed ex-tax vs ex-tax commitment) ──
  itp.total_billed_against_po,
  itp.invoice_count_on_po,
  itp.rejected_line_count_on_po,
  -- The ratio is NULL where there is no real commitment (~5.8% of POs have a
  -- commitment under $100 / null / zero — open / framework / placeholder POs),
  -- with commitment_quality flagging which case applies.
  CASE
    WHEN ph.po_total_committed >= 100
    THEN SAFE_DIVIDE(itp.total_billed_against_po, ph.po_total_committed)
    ELSE NULL
  END                                                     AS billing_progress_ratio,
  CASE
    WHEN ph.po_total_committed IS NULL THEN 'no_commitment'
    WHEN ph.po_total_committed = 0     THEN 'zero_commitment'
    WHEN ph.po_total_committed < 100   THEN 'nominal_commitment'
    ELSE 'real_commitment'
  END                                                     AS commitment_quality,

  -- ── SAP payment data (NULL where not matched in SAP) ──
  sp.sap_posted_amount,
  sp.sap_posting_date,
  sp.sap_payment_type,
  sp.sap_vendor_id,
  sp.sap_posting_count,
  -- SAP total vs invoice total billed (ex-tax). ~1.0 = paid as billed;
  -- a material deviation is a reconciliation flag.
  SAFE_DIVIDE(sp.sap_posted_amount, it.invoice_billed_ex_tax) AS sap_to_billed_ratio,

  -- ── approval chain ──
  ap.chain_length,
  ap.first_approval_date,
  ap.final_approval_date,
  ap.final_actor                                          AS final_approver_actor,
  ap.app_1_nominee, ap.app_1_actor, ap.app_1_date,
  ap.app_2_nominee, ap.app_2_actor, ap.app_2_date,
  ap.app_3_nominee, ap.app_3_actor, ap.app_3_date,
  ap.app_4_nominee, ap.app_4_actor, ap.app_4_date,
  ap.app_5_nominee, ap.app_5_actor, ap.app_5_date,
  ap.app_6_nominee, ap.app_6_actor, ap.app_6_date,
  ap.app_7_nominee, ap.app_7_actor, ap.app_7_date,

  -- ── derived ratios / gaps ──
  SAFE_DIVIDE(il.billed_amount_ex_tax, ph.po_total_committed) AS line_to_po_total_ratio,
  DATE_DIFF(il.invoice_date, ph.po_date, DAY)             AS po_to_invoice_days,
  DATE_DIFF(il.paid_date, il.invoice_date, DAY)           AS invoice_to_paid_days,

  -- ── anomaly-model features ──
  il.payment_terms_days,

  -- date gaps (po_to_invoice_days above already covers PO->invoice)
  DATE_DIFF(ap.final_approval_date, ph.po_date, DAY)      AS days_approval_minus_po,
  DATE_DIFF(ap.final_approval_date, il.invoice_date, DAY) AS days_approval_minus_invoice,

  -- lag-to-terms ratios
  SAFE_DIVIDE(
    DATE_DIFF(il.invoice_date, ph.po_date, DAY),
    NULLIF(il.payment_terms_days, 0)
  )                                                       AS invoice_lag_to_terms_ratio,
  SAFE_DIVIDE(
    DATE_DIFF(ap.final_approval_date, il.invoice_date, DAY),
    NULLIF(il.payment_terms_days, 0)
  )                                                       AS approval_lag_invoice_to_terms_ratio,
  SAFE_DIVIDE(
    DATE_DIFF(ap.final_approval_date, ph.po_date, DAY),
    NULLIF(il.payment_terms_days, 0)
  )                                                       AS approval_lag_po_to_terms_ratio,

  -- payment-amount ratios (from the SAP posted amount, exposed once as
  -- sap_posted_amount above). Compared to the INVOICE total, populated only
  -- where SAP matched (~66%); NULL otherwise.
  SAFE_DIVIDE(sp.sap_posted_amount, it.invoice_billed_ex_tax) AS payment_to_invoice_ratio,
  SAFE_DIVIDE(it.invoice_gst, sp.sap_posted_amount)       AS tax_to_payment_ratio,

  -- ── blocked vendor (point-in-time status from the vendor master) ──
  vsl.vendor_status,
  CASE
    WHEN vsl.vendor_number IS NULL                         THEN NULL
    WHEN vsl.vendor_status IS NULL OR vsl.vendor_status='' THEN TRUE
    WHEN vsl.vendor_status <> 'A'                          THEN TRUE
    ELSE FALSE
  END                                                     AS flag_blocked_vendor_active,

  -- ── DOA — authority limit per approver in the chain, vs the PO commitment ──
  d1.doa_annual_limit AS app_1_doa_limit,
  d2.doa_annual_limit AS app_2_doa_limit,
  d3.doa_annual_limit AS app_3_doa_limit,
  d4.doa_annual_limit AS app_4_doa_limit,
  d5.doa_annual_limit AS app_5_doa_limit,
  d6.doa_annual_limit AS app_6_doa_limit,
  d7.doa_annual_limit AS app_7_doa_limit,
  GREATEST(
    COALESCE(d1.doa_annual_limit, 0), COALESCE(d2.doa_annual_limit, 0),
    COALESCE(d3.doa_annual_limit, 0), COALESCE(d4.doa_annual_limit, 0),
    COALESCE(d5.doa_annual_limit, 0), COALESCE(d6.doa_annual_limit, 0),
    COALESCE(d7.doa_annual_limit, 0)
  )                                                       AS max_chain_doa_limit,
  CASE
    WHEN ph.po_total_committed IS NULL THEN NULL
    WHEN COALESCE(d1.doa_annual_limit, d2.doa_annual_limit, d3.doa_annual_limit,
                  d4.doa_annual_limit, d5.doa_annual_limit, d6.doa_annual_limit,
                  d7.doa_annual_limit) IS NULL THEN NULL
    WHEN ph.po_total_committed > GREATEST(
           COALESCE(d1.doa_annual_limit, 0), COALESCE(d2.doa_annual_limit, 0),
           COALESCE(d3.doa_annual_limit, 0), COALESCE(d4.doa_annual_limit, 0),
           COALESCE(d5.doa_annual_limit, 0), COALESCE(d6.doa_annual_limit, 0),
           COALESCE(d7.doa_annual_limit, 0))
      THEN TRUE
    ELSE FALSE
  END                                                     AS flag_po_exceeds_all_doa,
  SAFE_DIVIDE(
    ph.po_total_committed,
    NULLIF(GREATEST(
      COALESCE(d1.doa_annual_limit, 0), COALESCE(d2.doa_annual_limit, 0),
      COALESCE(d3.doa_annual_limit, 0), COALESCE(d4.doa_annual_limit, 0),
      COALESCE(d5.doa_annual_limit, 0), COALESCE(d6.doa_annual_limit, 0),
      COALESCE(d7.doa_annual_limit, 0)), 0)
  )                                                       AS po_to_max_doa_ratio,

  -- ── match diagnostics ──
  CASE
    WHEN ph.po_order_id IS NOT NULL THEN 'po_header'
    ELSE 'orphan'
  END                                                     AS match_method,
  CASE
    WHEN sp.k_invoice IS NOT NULL THEN 'sap_matched'
    ELSE 'sap_unmatched'
  END                                                     AS sap_match,

  CURRENT_TIMESTAMP()                                     AS _loaded_at

FROM invoice_lines il
LEFT JOIN po_header ph
  ON UPPER(TRIM(il.po_number)) = UPPER(TRIM(ph.po_order_id))
LEFT JOIN approvals_pivoted ap
  ON ap.Approvable_ID = ph.approvable_id
LEFT JOIN invoice_totals_per_po itp
  ON itp.po_number = il.po_number
LEFT JOIN invoice_totals it
  ON it.invoice_id = il.invoice_id
LEFT JOIN vendor_status_lookup vsl
  ON vsl.vendor_number = UPPER(TRIM(ph.vendor_number))
LEFT JOIN doa_unique d1 ON d1.approver_upper = UPPER(TRIM(ap.app_1_actor))
LEFT JOIN doa_unique d2 ON d2.approver_upper = UPPER(TRIM(ap.app_2_actor))
LEFT JOIN doa_unique d3 ON d3.approver_upper = UPPER(TRIM(ap.app_3_actor))
LEFT JOIN doa_unique d4 ON d4.approver_upper = UPPER(TRIM(ap.app_4_actor))
LEFT JOIN doa_unique d5 ON d5.approver_upper = UPPER(TRIM(ap.app_5_actor))
LEFT JOIN doa_unique d6 ON d6.approver_upper = UPPER(TRIM(ap.app_6_actor))
LEFT JOIN doa_unique d7 ON d7.approver_upper = UPPER(TRIM(ap.app_7_actor))
-- SAP joins at INVOICE level on the invoice number. Every line of an invoice
-- gets the same invoice-level payment data — do not sum it across lines.
LEFT JOIN sap_payments sp
  ON sp.k_invoice = UPPER(TRIM(il.invoice_id));
