CREATE OR REPLACE VIEW `fraud.sap_same_invoice_payment_date_vw`
AS
WITH
  pt AS (
    SELECT DISTINCT
      vendor,
      Payment_Terms AS payment_terms,
      Payment_Terms_Desc AS payment_terms_description,
    FROM gcp-wow-ent-im-tbl-prod.gs_smkt_fin_data.fin_vwc_analysis_v fin
  ),
  raw_data AS (
    SELECT DISTINCT
      i.Vendor,
      i.Vendor_Name,
      i.Supplier_Custom_Category_L2,
      Invoice_Date,
      Invoice_desc Invoice_Number,
      Invoice_Amt,
      D_Clrng_doc,
      Payment_Date_Woolies,
      Payment_Amount,
      Payment_Terms,
      Payment_Terms_Description,
      i.System
    FROM gcp-wow-risk-de-data-prod.fraud.sap_invoices i
    INNER JOIN gcp-wow-risk-de-data-prod.fraud.base_payment p
      ON i.D_Clrng_doc = p.Payment_Clearing_Doc
    INNER JOIN pt v
      ON v.vendor = i.Vendor
    WHERE i.Invoice_Date = p.Payment_Date_Woolies
  )

-- Detect potential early payments by scanning for vendor payments made on the same day as the invoice date (or invoice receipt date), even though the vendor has payment terms greater than 0 days
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'SAP-Detect potential early payments by scanning for vendor payments made on the same day as the invoice date (or invoice receipt date), even though the vendor has payment terms greater than 0 days'
    AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  f.*,

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
FROM raw_data f
WHERE Payment_Terms <> 'N005'
ORDER BY Vendor, Invoice_Number;
