CREATE OR REPLACE VIEW `gcp-wow-risk-de-data-prod.fraud.sap_dupe_invoices_vw` AS
WITH
  -- 1. Get filtered vendor list (clean IDs for joining)
  vendors AS (
    SELECT DISTINCT vendor_ID, supplier_name, Supplier_Custom_Category_L2
    FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v`
    WHERE company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),

  -- 2. Base BSEG data with date parsing
  bseg_data AS (
    SELECT 
      bseg.H_Reference AS Invoice_Number,
      PARSE_DATE('%Y%m%d', CAST(bseg.H_Document_Date AS STRING)) AS Invoice_Date_Obj,
      FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.H_Document_Date)) AS Invoice_Date,
      bseg.D_Purchasing_Doc AS PO_Number,
      bseg.H_DocHeader_Text AS Inv_Description,
      bseg.D_Amount,
      bseg.D_Amount_in_LC,
      bseg.D_GL_Amount,
      bseg.D_Cost_Center,
      bseg.H_Document_Type,
      CASE
        WHEN bseg.H_Document_Type = 'Y0' THEN 'Ariba_WDP'
        WHEN bseg.H_Document_Type IN ('PX', 'PY', 'VS') THEN 'PEPS'
        WHEN bseg.H_Document_Type = 'YM' THEN 'Maximo'
        ELSE 'SAP'
      END AS Purchasing_System
    FROM `gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v` bseg
    WHERE H_Company_Code = '1000'
      AND CAST(FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.H_Document_Date))AS DATE) >=DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
      AND H_Document_Type IN ('PX', 'PY', 'VS', 'Y0', 'YM')
  ),

  -- 3. Purchasing data
  purchasing_data AS (
    SELECT
      sl.PurchasingDocumentNumber,
      sl.PurchasingDocumentDate AS PO_Date,
      sl.Vendor,
      sl.PurchasingItemShortText
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_purchasing_view.document_schedule_lines_v` sl
    WHERE PurchasingDocumentDate >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
      AND PurchasingOrganization = '1000'
  ),

  -- 4. Join and Aggregate (Collapsing line items per Invoice ID)
  joined_data AS (
    SELECT 
      Invoice_Number,
      Invoice_Date,
      Invoice_Date_Obj,
      PO_Number,
      PO_Date,
      Inv_Description,
      Vendor,
      PurchasingItemShortText,
      D_Cost_Center,
      Purchasing_System,
      SUM(D_Amount) AS D_Amount,
      SUM(D_GL_amount) AS D_GL_amount,
      SUM(D_Amount_in_LC) AS D_Amount_in_LC
    FROM bseg_data
    JOIN purchasing_data ON purchasing_data.PurchasingDocumentNumber = bseg_data.PO_Number
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
  ),

  -- 5. Final Vendor filtering
  filtered_vendors AS (
    SELECT 
      pc1.PO_Number AS PO_Order_Id,
      pc1.PO_Date,
      pc1.Invoice_Number AS Invoice_ID,
      pc1.Invoice_Date,
      pc1.Invoice_Date_Obj,
      pc1.PurchasingItemShortText AS Inv_Description,
      '' AS Invoice_Status,
      pc1.D_Amount_in_LC AS sum_Paid_Amount_AUD,
      v.Vendor AS ERP_Supplier_ID,
      pc1.Purchasing_System,
      v.VendorDescription AS ERP_Supplier
    FROM joined_data pc1
    JOIN `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v 
      ON ltrim(v.Vendor, '0') = ltrim(pc1.Vendor, '0')
    JOIN vendors fv 
      ON ltrim(fv.vendor_ID, '0') = ltrim(v.Vendor, '0')
  ),

  -- 6. Grouping Logic (Gaps and Islands)
  group_signals AS (
    SELECT *,
      LAG(Invoice_Date) OVER (PARTITION BY ERP_Supplier_ID, sum_Paid_Amount_AUD ORDER BY Invoice_Date, Invoice_ID) AS prev_date
    FROM filtered_vendors
  ),
  
  group_assignment AS (
    SELECT *,
      SUM(CASE WHEN prev_date IS NULL OR DATE_DIFF(CAST(Invoice_Date as DATE), CAST(prev_date AS DATE), DAY)>= 3 THEN 1 ELSE 0 END) 
        OVER (ORDER BY ERP_Supplier_ID, sum_Paid_Amount_AUD, Invoice_Date, Invoice_ID) AS group_number
    FROM group_signals
  ),

  -- 7. Identify valid duplicate groups
  final_output AS (
    SELECT *,
      COUNT(DISTINCT Invoice_ID) OVER (PARTITION BY group_number) AS unique_id_count,
      COUNT(DISTINCT Inv_Description) OVER (PARTITION BY group_number) AS unique_desc_count
    FROM group_assignment
  )

-- Final Selection with all original columns and descriptions
SELECT 
  'Facilities Management Services' AS vendor_area,
  'Payments' AS routine_category,
  'Scan duplicate invoices having same amount, same vendor (even if PO numbers are different) raised in a span of 0-3 days' AS routine_description,
  'Duplicate Invoice' AS metric_description,
  'Count' AS metric_unit,
  f.Invoice_ID AS invoice_id,
  CAST(f.Invoice_Date AS date) AS invoice_date,
  f.Inv_Description AS inv_description,
  f.Invoice_Status AS invoice_status,
  f.sum_Paid_Amount_AUD AS invoice_amt_paid,
  f.ERP_Supplier_ID,
  f.ERP_Supplier,
  f.group_number,
  f.Purchasing_System AS System,
  CONCAT('group ', CAST(f.group_number AS STRING)) AS dupe_invoice_group,

  -- Time bucket flags
  CASE WHEN CAST(f.Invoice_Date AS date) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY) AND CURRENT_DATE() THEN 'Y' ELSE 'N' END AS last_week,
  CASE WHEN CAST(f.Invoice_Date AS date) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH) AND CURRENT_DATE() THEN 'Y' ELSE 'N' END AS last_month,
  CASE WHEN CAST(f.Invoice_Date AS date) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY) AND CURRENT_DATE() THEN 'Y' ELSE 'N' END AS last_90_days,
  CASE WHEN CAST(f.Invoice_Date AS date) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY) AND CURRENT_DATE() THEN 'Y' ELSE 'N' END AS last_180_days,
  CASE WHEN CAST(f.Invoice_Date AS date) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR) AND CURRENT_DATE() THEN 'Y' ELSE 'N' END AS last_year,
  CASE WHEN CAST(f.Invoice_Date AS date) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR) AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR) THEN 'Y' ELSE 'N' END AS last_last_year
FROM final_output f
WHERE unique_id_count > 1 
  AND unique_desc_count > 1
ORDER BY f.group_number;
