CREATE OR REPLACE VIEW `fraud.sap_payment_exceeding_invoice_amount_vw`
AS
WITH
  invoice_payment AS (
    SELECT
      p.D_Vendor,
      p.Vendor_Name,
      p.Supplier_Custom_Category_L2,
      p.Payment_Date_Woolies,
      p.D_GL_Account,
      p.Payment_Date_Appears_In_Vendor_Account,
      p.Payment_Clearing_Doc,
      p.Payment_Amount,
      i.Invoice_Date,
      i.Invoice_desc,
      i.Invoice_Number,
      i.Invoice_Amt,
      i.System,
      sum(i.Invoice_Amt) OVER (PARTITION BY i.D_Clrng_doc) AS invoice_total
    FROM gcp-wow-risk-de-data-prod.fraud.base_payment p
    INNER JOIN gcp-wow-risk-de-data-prod.fraud.sap_invoices i
      ON p.Payment_Clearing_Doc = i.D_Clrng_doc
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'SAP - Scan for payments exceeding invoiced amount' AS routine_description,
  'Invoice' AS metric_description,
  'Count' AS metric_unit,
  ip.*,
  CASE
    WHEN
      CAST(Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM
  invoice_payment ip
WHERE invoice_total > payment_amount;
