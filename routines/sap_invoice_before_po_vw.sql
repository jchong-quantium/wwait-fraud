-- SAP

CREATE OR REPLACE VIEW gcp-wow-risk-de-data-prod.fraud.sap_invoices_before_po_vw
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L2
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  document_line AS (
    SELECT DISTINCT
      sl.PurchasingDocumentNumber,
      sl.PurchasingDocumentDate AS PO_Date,
      sl.Vendor,
      sl.PurchasingItemShortText,
      sl.NetOrderValue AS PO_amount,
    FROM
      `gcp-wow-ent-im-tbl-prod.adp_dm_purchasing_view.document_schedule_lines_v`
        sl
    WHERE
      PurchasingDocumentDate >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
      AND PurchasingOrganization = '1000'
  ),
  bkpf_bseg AS (
    SELECT
      H_Reference,
      FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', H_Document_Date))
        AS Invoice_Date,
      D_Purchasing_Doc AS PO_Number,
      H_DocHeader_Text AS Inv_Description,
      D_Amount,
      D_Amount_in_LC,
      D_GL_Amount,
      bseg.D_Cost_Center,
      bseg.H_Document_Type,  -- <== This line was missing a comma originally
      CASE
        WHEN bseg.H_Document_Type = 'Y0' THEN 'Ariba_WDP'
        WHEN bseg.H_Document_Type IN ('PX', 'PY', 'VS') THEN 'PEPS'
        WHEN bseg.H_Document_Type = 'YM' THEN 'Maximo'
        ELSE 'SAP'
        END AS Purchasing_System,
    FROM
      gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v bseg
    WHERE
      H_Company_Code = '1000'
      AND PARSE_DATE('%Y%m%d', CAST(H_Document_Date AS STRING))
        >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
  ),
  unagg_po_invoice AS (
    SELECT DISTINCT
      H_Reference AS Invoice_Number,
      Invoice_Date,
      sl.PO_Date,
      sl.Vendor,
      sl.PurchasingItemShortText,
      sl.PO_amount,
      v.VendorDescription,
      PO_Number,
      Inv_Description,
      D_Amount,
      D_Amount_in_LC,
      D_GL_Amount,
      bseg.D_Cost_Center,
      bseg.H_Document_Type,  -- <== This line was missing a comma originally
      CASE
        WHEN bseg.H_Document_Type = 'Y0' THEN 'Ariba_WDP'
        WHEN bseg.H_Document_Type IN ('PX', 'PY', 'VS') THEN 'PEPS'
        WHEN bseg.H_Document_Type = 'YM' THEN 'Maximo'
        ELSE 'SAP'
        END AS Purchasing_System,
      Supplier_Custom_Category_L2
    FROM bkpf_bseg bseg
    INNER JOIN document_line sl
      ON sl.PurchasingDocumentNumber = bseg.PO_Number
    INNER JOIN `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
      ON ltrim(v.Vendor, '0') = ltrim(sl.vendor, '0')
    INNER JOIN vendors r
      ON ltrim(r.vendor_ID, '0') = ltrim(sl.Vendor, '0')
    WHERE
      bseg.H_Document_Type IN ('PX', 'PY', 'VS', 'Y0', 'YM')
  ),
  agg_po_invoice AS (
    SELECT DISTINCT
      Invoice_Number,
      Invoice_Date,
      PO_Number,
      PO_Date,
      Inv_Description,
      Vendor,
      VendorDescription,
      PurchasingItemShortText,
      D_Cost_Center,
      Purchasing_System,
      Supplier_Custom_Category_L2,
      sum(D_Amount) AS D_Amount,
      sum(D_GL_amount) AS D_GL_amount,
      sum(D_Amount_in_LC) AS D_Amount_in_LC,
      sum(PO_amount) AS sum_PO_Spend_AUD
    FROM unagg_po_invoice
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
  )

-- PurchasingItemShortText
-- select pc1.*, v.VendorDescription , fv.Supplier_Custom_Category_L2 AS vendor_area
--  from gcp-wow-risk-de-lab-dev.Fraud.SAP_2 pc1 inner join `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v on ltrim(v.Vendor, '0') = ltrim(pc1.vendor,'0')
-- inner join gcp-wow-risk-de-lab-dev.Fraud.filtered_suppliers fv on ltrim(fv.Supplier_ID,'0')  = ltrim(v.Vendor, '0');
-- Create or replace table gcp-wow-risk-de-data-prod.fraud.ariba_invoices_before_po as
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Invoices dated before their matched PO dates' AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  f.PO_Number AS PO_Order_Id,
  f.PO_Date,
  sum_PO_Spend_AUD,
  '' AS PO_Status,
  f.Invoice_Number AS invoice_id,
  CAST(f.Invoice_Date AS date) AS invoice_date,
  f.INV_Description AS inv_description,
  '' AS invoice_status,
  f.D_Amount_in_LC AS invoice_amt,
  f.Vendor AS ERP_Supplier_ID,
  f.VendorDescription AS ERP_Supplier,
  purchasing_system AS System,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM agg_po_invoice f
WHERE CAST(f.Invoice_Date AS date) <= f.PO_Date
ORDER BY f.VendorDescription;
