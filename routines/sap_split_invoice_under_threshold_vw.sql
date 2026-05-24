CREATE OR REPLACE VIEW `fraud.sap_split_invoice_under_threshold_vw`
AS
WITH
  invoice_agg AS (
    SELECT
      Vendor AS Vendor_Number,
      Vendor_Name AS Vendor_Description,
      Supplier_Custom_Category_L2,
      CAST(Invoice_Date AS DATE) AS Invoice_Date,
      Invoice_desc,
      Invoice_Number,
      H_USNAM_User_name,
      D_GL_Account,
      System,
      SUM(Invoice_Amt) AS Invoice_Amt
    FROM `gcp-wow-risk-de-data-prod.fraud.sap_invoices`
    WHERE Invoice_Amt <> 0
    GROUP BY
      Vendor, Vendor_Name, Supplier_Custom_Category_L2, Invoice_Date,
      Invoice_desc, Invoice_Number, H_USNAM_User_name, D_GL_Account, System
  ),

  -- Only keep invoices under $50K
  filtered_invoices AS (
    SELECT *
    FROM invoice_agg
    WHERE Invoice_Amt < 50000
  ),

  -- Group invoices from same vendor and same invoice date
  grouped_invoices AS (
    SELECT
      Vendor_Number,
      Vendor_Description,
      Invoice_Date,
      COUNT(DISTINCT Invoice_Number) AS invoice_count,
      SUM(Invoice_Amt) AS total_group_amount
    FROM filtered_invoices
    GROUP BY Vendor_Number, Vendor_Description, Invoice_Date
    HAVING
      COUNT(DISTINCT Invoice_Number) > 1
      AND SUM(Invoice_Amt) >= 50000
  ),

  -- Add group IDs and bring back invoice-level detail
  flagged_invoices AS (
    SELECT
      f.*,
      g.total_group_amount,
      DENSE_RANK() OVER (ORDER BY g.Vendor_Number, g.Invoice_Date) AS group_id,
      CONCAT(
        'Group ', DENSE_RANK() OVER (ORDER BY g.Vendor_Number, g.Invoice_Date))
        AS split_invoice_group
    FROM filtered_invoices f
    INNER JOIN grouped_invoices g
      ON
        f.Vendor_Number = g.Vendor_Number
        AND f.Invoice_Date = g.Invoice_Date
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Detect potential invoice splitting by identifying multiple invoices from the same vendor on the same day where the combined total exceeds the threshold of $50,000.'
    AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  Vendor_Number AS Vendor,
  Vendor_Description,
  Invoice_Date,
  total_group_amount AS Total_Group_Invoice_Amount,
  Invoice_Number AS Invoice_ID,
  Invoice_Amt AS Invoice_Amount_Ex_Tax,
  group_id AS Group_ID,
  split_invoice_group AS SplitInvoice_Group,
  Invoice_desc AS INV_Description,
  '' AS Reconciliation_Status,
  System,

  -- Time flags
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM flagged_invoices
--ORDER BY group_id ASC
;
