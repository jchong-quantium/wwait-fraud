-- =============================================================================
-- base_transaction
-- Unified transaction table — Ariba branch only (Phase 1)
--
-- CURRENT STATE: Ariba branch only
-- SAP branch to be added once bkpf_bseg_accounting_doc_v access is confirmed
--
-- OUTSTANDING DATA ACCESS REQUIRED:
-- [D1] gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v
--      Needed for: payment_date, payment_amount (SAP), invoice_date (SAP),
--      invoice_amount_excl_tax (SAP), gl_account, SAP branch entirely
--      Status: BLOCKED — awaiting gcp-wow-ent-im-tbl-prod project access
--
-- [D2] gcp-wow-risk-de-data-prod.audit_group_enablement.doa
--      Needed for: approver_doa_annual_limit
--      Status: BLOCKED — awaiting gcp-wow-risk-de-data-prod project access
--
-- [D3] gcp-wow-fac-de-data-prod.maximo.PO / COMPANIES / PERSON
--      Needed for: Maximo branch of base_transaction
--      Status: PARKED — Maximo coverage to be confirmed with Gopi before building
--
-- KNOWN LIMITATIONS IN CURRENT BUILD:
-- [L1] Ariba branch is at PO + Invoice grain after deduplication in ariba_raw.
--      The source view (ariba_po_invoice_vw) is at PO + cost_centre + invoice +
--      description grain. ariba_raw re-aggregates to PO + invoice using SUM for
--      truly-additive fields and MAX for header-level broadcast fields.
--      Cost centre is NULLed when multiple distinct values exist per PO + invoice.
--
--      IMPORTANT: PO_Spend is a PO-HEADER broadcast value (repeated across every
--      cost-centre/invoice/description row of the same PO), NOT an additive
--      line-level field. So we use MAX(PO_Spend), not SUM. Validated 2026-05 by
--      cross-checking SUM(po_spend) per vendor against source — SUM produced
--      200%–17,000% inflation; MAX matches source within ~5%.
--
-- [L2] payment_date is NULL for all Ariba rows — payment events live in SAP
--      (bkpf_bseg_accounting_doc_v). Will be populated when SAP branch is added.
--
-- [L3] po_last_modified_date is NULL for all Ariba rows — no equivalent field
--      in Silver_Ariba_PO_Linelevel_v. Available in SAP via DocumentLastChangedOn
--      in document_schedule_lines_v. Will be populated when SAP branch is added.
--
-- [L4] approver_doa_annual_limit is NULL for all rows — requires
--      audit_group_enablement.doa which is in gcp-wow-risk-de-data-prod.
--      See [D2] above.
--
-- [L5] gl_account is NULL for all Ariba rows — GL account is assigned at SAP
--      posting time, not in Ariba. Will be populated when SAP branch is added.
--
-- [L6] payment_terms_description and payment_terms_days have been omitted
--      pending a reliable parsed source. payment_terms carries the raw code
--      string from Silver_Ariba_PO_Linelevel_v (e.g. N006 - 60 days from
--      end of month). Parsing logic to be added in a future iteration.
--
-- [L7] Contract-backed invoices (order_id = Unclassified in
--      Silver_Ariba_POandInvoices_v) are excluded. These are invoices raised
--      against a contract rather than a PO and have no PO reference to join on.
--      Estimated materiality to be confirmed with Gopi.
--
-- TRANSACTION-PATTERN FLAGS (added 2026-05):
-- [F1] 12 boolean flag columns at transaction grain, encoding known fraud-
--      signal patterns from (a) existing WW routines (e.g. invoices_before_po,
--      sap_payment_blocked_vendor), (b) W360 historical findings (DOA bypass,
--      retro-billing, inflated hours), (c) validation findings during EDA.
--      Each flag is one CASE expression; logic and origin documented inline
--      in the ariba_with_flags CTE below.
--
-- [F2] flag_blocked_vendor_active requires a vendor_status lookup. This is
--      computed once in vendor_status_lookup CTE and joined on vendor_number.
--      vendor_attributes is the source (it exposes VendorStatus from
--      dim_vendor_v with values A/B/C/NULL).
--
-- [F3] Flag value semantics:
--        TRUE  = pattern fires
--        FALSE = pattern does not fire
--        NULL  = cannot evaluate (e.g. missing date field)
--      Downstream aggregations must treat NULL as "not counted" — use
--      COUNTIF(flag IS TRUE), not COUNTIF(flag).
--
-- GRAIN:
--      Ariba branch: one row per PO + Invoice
--      SAP branch (pending): one row per SAP document + invoice
--      Combined: UNION ALL of both branches
--
-- REFRESH:
--      Monthly — aligned with existing routine refresh cycle
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.base_transaction`
AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- VENDOR STATUS LOOKUP [F2]
-- Used by flag_blocked_vendor_active. Joined to ariba_raw on vendor_number.
-- Status semantics (from sap_payment_blocked_vendor_vw, the canonical
-- routine):
--   'A'       = active
--   'B'       = payment block
--   'C'       = procurement block
--   NULL / '' = no status set ("No Response")
-- ─────────────────────────────────────────────────────────────────────────────

vendor_status_lookup AS (
  SELECT
    vendor_number,
    vendor_status
  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.vendor_attributes`
),

-- ─────────────────────────────────────────────────────────────────────────────
-- ARIBA APPROVALS
-- Source: gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_Approvals_v
-- Extracts last approved action per requisition
-- Filters: Approved state only, excludes system placeholder rows (NULL Real_User)
-- Note: Approver <> Real_User indicates someone acted on behalf of another person
--       (delegation / leave coverage) — captured as acted_on_behalf_of flag
-- ─────────────────────────────────────────────────────────────────────────────

ariba_last_approver AS (
  SELECT
    Approvable_ID,
    Real_User                                             AS approved_by_user,
    Approver                                              AS nominated_approver,
    CAST(Action_Date AS DATE)                             AS approval_date,
    CASE
      WHEN Approver <> Real_User THEN TRUE
      ELSE FALSE
    END                                                   AS acted_on_behalf_of
  FROM (
    SELECT
      Approvable_ID,
      Real_User,
      Approver,
      Action_Date,
      ROW_NUMBER() OVER (
        PARTITION BY Approvable_ID
        ORDER BY Action_Date DESC
      ) AS rn
    FROM
      `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_Approvals_v`
    WHERE
      Approver_State = 'Approved'
      AND Real_User IS NOT NULL
      AND Real_User <> ''
  )
  WHERE rn = 1
),

-- ─────────────────────────────────────────────────────────────────────────────
-- ARIBA RAW
-- Source: ${GCP_PROJECT_ID}.${BQ_DATASET}.ariba_po_invoice_vw
-- Reads from the recreated view which replicates ariba_po_invoice_vw from the
-- risk team's dataset. Joins approvals on Requisition_ID.
--
-- RE-AGGREGATION NOTE [L1]:
-- The view is at PO + cost_centre + invoice + description grain.
-- This CTE re-aggregates to PO + invoice grain to avoid double-counting spend
-- in the vendor rollup layer.
--   - SUM(PO_Spend): additive across cost centre rows — produces true PO total
--   - SUM(amount_invoiced): additive across description lines — produces true
--     invoice total
--   - MAX(Amount_Paid): header-level field repeated on every line — take once
--   - MAX(amount_paid_excl_tax): same as Amount_Paid
--   - SUM(tax_paid): line-level and additive
--   - cost_centre: NULLed when multiple distinct values exist per PO + invoice
--     (multi-store POs span many cost centres)
-- ─────────────────────────────────────────────────────────────────────────────

ariba_raw AS (
  SELECT
    po.PO_Number                                          AS po_number,
    po.Invoice_ID                                         AS invoice_id,
    po.Vendor_Number                                      AS vendor_number,
    po.Requisition_ID                                     AS requisition_id,
    po.PO_Status                                          AS po_status,
    CAST(po.PO_Date AS DATE)                              AS po_date,
    CAST(po.Invoice_date AS DATE)                         AS invoice_date,

    -- [L2] payment_date NULL — payment events live in SAP bkpf_bseg
    -- will be populated when SAP branch is added [D1]
    CAST(NULL AS DATE)                                    AS payment_date,

    -- [L3] po_last_modified_date NULL — no equivalent in Ariba source tables
    -- available in SAP via DocumentLastChangedOn in document_schedule_lines_v
    -- will be populated when SAP branch is added [D1]
    CAST(NULL AS DATE)                                    AS po_last_modified_date,

    -- approver_last: legacy field from ariba_po_invoice_vw which itself
    -- sources from Requester_Manager_L1. EDA confirmed this column is
    -- 100% "GORDON CAIRNS" (retired chairman) — i.e. unusable. Kept here
    -- for backwards-compatibility; downstream features should rely on
    -- nominated_approver / approved_by_user instead.
    po.Approver                                           AS approver_last,

    -- [L4] approver_doa_annual_limit NULL — requires audit_group_enablement.doa
    -- in gcp-wow-risk-de-data-prod, access pending [D2]
    CAST(NULL AS FLOAT64)                                 AS approver_doa_annual_limit,

    po.Requestor                                          AS requestor,
    po.invoice_status,
    po.reconciliation_status,
    po.Contract_Id                                        AS contract_id,
    po.payment_terms,
    la.approval_date,
    la.approved_by_user,
    la.nominated_approver,
    la.acted_on_behalf_of,

    -- amounts — aggregated to PO + invoice grain [L1]
    MAX(po.PO_Spend)                                      AS po_spend,                  -- MAX, not SUM: PO_Spend is a PO-header broadcast value (see [L1])
    SUM(po.amount_invoiced)                               AS invoice_amount_excl_tax,   -- SUM is correct: amount_invoiced is line-additive
    MAX(po.Amount_Paid)                                   AS payment_amount,
    MAX(po.amount_paid_excl_tax)                          AS amount_paid_excl_tax,
    SUM(po.tax_paid)                                      AS tax_amount,

    -- cost centre — NULL when multiple distinct values exist per PO + invoice [L1]
    CASE
      WHEN COUNT(DISTINCT
        CASE WHEN po.Cost_Center = '' OR po.Cost_Center = '0' THEN NULL
             ELSE po.Cost_Center
        END) = 1
        THEN MAX(CASE WHEN po.Cost_Center = '' OR po.Cost_Center = '0' THEN NULL
                      ELSE po.Cost_Center
                 END)
      ELSE NULL
    END                                                   AS cost_centre,

    -- [L5] gl_account NULL — assigned at SAP posting time, not in Ariba
    -- will be populated when SAP branch is added [D1]
    CAST(NULL AS STRING)                                  AS gl_account

  FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.ariba_po_invoice_vw` po
  LEFT JOIN ariba_last_approver la
    ON la.Approvable_ID = po.Requisition_ID
  GROUP BY
    po.PO_Number,
    po.Invoice_ID,
    po.Vendor_Number,
    po.Requisition_ID,
    po.PO_Status,
    CAST(po.PO_Date AS DATE),
    CAST(po.Invoice_date AS DATE),
    po.Approver,
    po.Requestor,
    po.invoice_status,
    po.reconciliation_status,
    po.Contract_Id,
    po.payment_terms,
    la.approval_date,
    la.approved_by_user,
    la.nominated_approver,
    la.acted_on_behalf_of
),

-- ─────────────────────────────────────────────────────────────────────────────
-- ARIBA WITH FLAGS [F1]
-- Adds 12 boolean transaction-pattern flag columns to ariba_raw. Each flag
-- encodes a known fraud-signal pattern. Logic is one CASE expression per
-- flag with inline comments documenting:
--   (a) the pattern in plain English
--   (b) the source routine or W360 case it derives from
--   (c) any reliability caveats
--
-- See [F1]–[F3] in the header for flag-layer semantics.
-- ─────────────────────────────────────────────────────────────────────────────

ariba_with_flags AS (
  SELECT
    bt.*,

    -- ============ DATE-ORDERING FLAGS ============

    -- flag_invoice_before_po
    -- Pattern: invoice issued before its matching PO was raised.
    -- Source: ariba_invoices_before_po_vw (WHERE Invoice_Date <= PO_Date)
    -- W360 link: 2024 audit found 183 vendors / 122 staff / $7.4M flagged.
    -- EDA fire rate: ~21% of rows.
    CASE
      WHEN bt.invoice_date IS NULL OR bt.po_date IS NULL THEN NULL
      WHEN bt.invoice_date < bt.po_date THEN TRUE
      ELSE FALSE
    END                                                   AS flag_invoice_before_po,

    -- flag_invoice_same_day_as_po
    -- Pattern: invoice issued on the same day as the PO.
    -- Origin: W360 retro-billing pattern (no dedicated routine).
    -- EDA fire rate: ~2.7%.
    CASE
      WHEN bt.invoice_date IS NULL OR bt.po_date IS NULL THEN NULL
      WHEN bt.invoice_date = bt.po_date THEN TRUE
      ELSE FALSE
    END                                                   AS flag_invoice_same_day_as_po,

    -- flag_approval_after_po
    -- Pattern: approval action recorded AFTER the PO was raised.
    -- EDA fire rate: ~80% (very common — captures "last workflow action
    -- on the requisition" semantic rather than retro-approval).
    -- Likely too common to be discriminative; carry through for now and
    -- evaluate in the model. Drop if uninformative.
    CASE
      WHEN bt.approval_date IS NULL OR bt.po_date IS NULL THEN NULL
      WHEN bt.approval_date > bt.po_date THEN TRUE
      ELSE FALSE
    END                                                   AS flag_approval_after_po,

    -- flag_approval_after_invoice
    -- Pattern: approval action recorded AFTER the invoice was issued.
    -- W360 link: 2024 audit "Invoices submitted before work orders".
    -- EDA fire rate: ~20%.
    CASE
      WHEN bt.approval_date IS NULL OR bt.invoice_date IS NULL THEN NULL
      WHEN bt.approval_date > bt.invoice_date THEN TRUE
      ELSE FALSE
    END                                                   AS flag_approval_after_invoice,

    -- ============ APPROVAL-PATTERN FLAGS ============

    -- flag_acted_on_behalf_of
    -- Pattern: nominee != actor in the last approval step (delegation).
    -- Origin: already present as acted_on_behalf_of; lift for consistency.
    -- EDA fire rate: ~5.6%.
    CASE
      WHEN bt.acted_on_behalf_of IS NULL THEN NULL
      WHEN bt.acted_on_behalf_of = TRUE THEN TRUE
      ELSE FALSE
    END                                                   AS flag_acted_on_behalf_of,

    -- flag_weekend_approval
    -- Pattern: approval action recorded on Saturday or Sunday.
    -- Origin: Tony's "out-of-hours approval" ask from kickoff meetings.
    -- BigQuery DAYOFWEEK: 1=Sun, 2=Mon, ..., 7=Sat.
    -- Caveat: approval_date is DATE (lost time-of-day); for hour-of-day
    -- signal, source from Silver_Ariba_Approvals_v.Action_Date (TIMESTAMP).
    CASE
      WHEN bt.approval_date IS NULL THEN NULL
      WHEN EXTRACT(DAYOFWEEK FROM bt.approval_date) IN (1, 7) THEN TRUE
      ELSE FALSE
    END                                                   AS flag_weekend_approval,

    -- ============ AMOUNT / VALUE FLAGS ============

    -- flag_high_value_po
    -- Pattern: PO above $50k threshold (split-PO routine logic).
    -- Threshold chosen to match ariba_split_po_under_threshold_vw —
    -- POs over $50k can't be "split to bypass DOA" in the way smaller
    -- ones can. Useful as a "high-attention" marker.
    CASE
      WHEN bt.po_spend IS NULL THEN NULL
      WHEN bt.po_spend > 50000 THEN TRUE
      ELSE FALSE
    END                                                   AS flag_high_value_po,

    -- flag_invoice_above_po
    -- Pattern: invoice amount exceeds PO amount by more than 5%.
    -- Source: ariba_invoices_not_matching_po_vw (loosened from
    -- HAVING ABS-diff>0 to >5% to avoid GST/rounding noise).
    -- W360 link: Operation Hoth — "excessive part markups (~30% vs 13%)".
    CASE
      WHEN bt.invoice_amount_excl_tax IS NULL OR bt.po_spend IS NULL
        OR bt.po_spend = 0 THEN NULL
      WHEN bt.invoice_amount_excl_tax > bt.po_spend * 1.05 THEN TRUE
      ELSE FALSE
    END                                                   AS flag_invoice_above_po,

    -- flag_round_amount
    -- Pattern: payment amount is an exact multiple of $100 AND > $1,000.
    -- Origin: W360 inflation patterns — fabricated invoices often use
    -- round numbers; legitimate ones reflect itemised pricing.
    -- Caveat: fires on many legitimate flat-fee invoices; useful only
    -- as part of an ensemble.
    CASE
      WHEN bt.payment_amount IS NULL THEN NULL
      WHEN bt.payment_amount > 1000
        AND MOD(CAST(bt.payment_amount AS INT64), 100) = 0 THEN TRUE
      ELSE FALSE
    END                                                   AS flag_round_amount,

    -- ============ STATUS / GOVERNANCE FLAGS ============

    -- flag_rejected_invoice
    -- Pattern: invoice in 'Rejected' status.
    -- A single rejected invoice isn't fraud, but a vendor with many
    -- rejections across time is worth attention.
    CASE
      WHEN bt.invoice_status IS NULL THEN NULL
      WHEN bt.invoice_status = 'Rejected' THEN TRUE
      ELSE FALSE
    END                                                   AS flag_rejected_invoice,

    -- flag_no_contract
    -- Pattern: PO has no contract_id (governance gap).
    -- Caveat: EDA found contract_id is rarely NULL on base_transaction
    -- but few distinct values, suggesting a placeholder pattern. Verify
    -- on first run and tighten if needed.
    CASE
      WHEN bt.contract_id IS NULL OR bt.contract_id = '' THEN TRUE
      ELSE FALSE
    END                                                   AS flag_no_contract,

    -- flag_blocked_vendor_active [F2]
    -- Pattern: transaction belongs to a vendor whose current vendor_status
    -- is not 'A' (active). Includes B, C, and empty/NULL ("No Response").
    -- Source: sap_payment_blocked_vendor_vw — same filter.
    -- Caveat: vendor_status is point-in-time. A vendor blocked today
    -- may have transacted legitimately when active. For time-accurate
    -- assessment, join DateLastChanged from dim_vendor_v (future work).
    CASE
      WHEN vsl.vendor_number IS NULL THEN NULL   -- vendor not in master
      WHEN vsl.vendor_status IS NULL OR vsl.vendor_status = '' THEN TRUE
      WHEN vsl.vendor_status <> 'A' THEN TRUE
      ELSE FALSE
    END                                                   AS flag_blocked_vendor_active

  FROM ariba_raw bt
  LEFT JOIN vendor_status_lookup vsl
    ON bt.vendor_number = vsl.vendor_number
)

-- ─────────────────────────────────────────────────────────────────────────────
-- FINAL OUTPUT
-- Ariba branch only — SAP branch (UNION ALL) to be added once [D1] is resolved
-- transaction_id: surrogate key constructed from po_number + invoice_id + system
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  CONCAT(
    COALESCE(po_number, 'NULL'), '|',
    COALESCE(invoice_id, 'NULL'), '|',
    'Ariba'
  )                                                       AS transaction_id,
  'Ariba'                                                 AS system,
  *
FROM ariba_with_flags

-- ─────────────────────────────────────────────────────────────────────────────
-- SAP BRANCH — PENDING [D1]
-- To be added as UNION ALL once the following views are recreated:
--   ${GCP_PROJECT_ID}.${BQ_DATASET}.base_payment_vw
--   ${GCP_PROJECT_ID}.${BQ_DATASET}.sap_invoices_vw
-- Source views depend on:
--   gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v
-- ─────────────────────────────────────────────────────────────────────────────
