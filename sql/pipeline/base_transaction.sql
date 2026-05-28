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
--      additive fields and MAX for header-level fields. Cost centre is NULLed
--      when multiple distinct values exist per PO + invoice.
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
-- BUSINESS UNIT LOOKUP
-- Source: gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
-- Deduplicates to one Business_div per PO_Document + Vendor_ID by picking the
-- most frequently occurring value. Excludes rows where PO_Document is NULL or empty.
-- Join key: po_number = PO_Document AND vendor_number = Vendor_ID
-- ─────────────────────────────────────────────────────────────────────────────

business_unit_lookup AS (
  SELECT
    PO_Document,
    Vendor_ID,
    Business_div
  FROM (
    SELECT
      PO_Document,
      Vendor_ID,
      Business_div,
      COUNT(*)                                              AS cnt,
      ROW_NUMBER() OVER (
        PARTITION BY PO_Document, Vendor_ID
        ORDER BY COUNT(*) DESC
      )                                                     AS rn
    FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v`
    WHERE PO_Document IS NOT NULL
      AND PO_Document <> ''
    GROUP BY PO_Document, Vendor_ID, Business_div
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
    SUM(po.PO_Spend)                                      AS po_spend,
    SUM(po.amount_invoiced)                               AS invoice_amount_excl_tax,
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
  LEFT JOIN business_unit_lookup bu
    ON bu.PO_Document = po.PO_Number
    AND bu.Vendor_ID = po.Vendor_Number
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
    la.acted_on_behalf_of,
    bu.Business_div
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
  *,
  CAST(Business_div AS STRING)                            AS business_unit
FROM ariba_raw

-- ─────────────────────────────────────────────────────────────────────────────
-- SAP BRANCH — PENDING [D1]
-- To be added as UNION ALL once the following views are recreated:
--   ${GCP_PROJECT_ID}.${BQ_DATASET}.base_payment_vw
--   ${GCP_PROJECT_ID}.${BQ_DATASET}.sap_invoices_vw
-- Source views depend on:
--   gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v
-- ─────────────────────────────────────────────────────────────────────────────
