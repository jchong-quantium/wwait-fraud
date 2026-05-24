CREATE OR REPLACE VIEW fraud.ariba_invoices_not_matching_po_vw
AS
WITH
  X AS (
    SELECT DISTINCT
      PO_Order_Id,
      PO_Date,
      PO_Status,
      PO_Spend AS sum_PO_Spend_AUD,
      Invoice_ID,
      Invoice_Date,
      INV_Description,
      Invoice_Status,
      PO_Amount_Invoiced AS invoice_amt,
      Contract_ID,
      INV_Contract_Id,
      vendor_number AS ERP_Supplier_ID,
      vendor_description AS ERP_Supplier,
      Supplier_Custom_Category_L2
    FROM fraud.ariba_po_invoice a
  ),

  -- Step 2: Identify POs where total invoice ≠ total PO
  PO_invoice_match_check AS (
    SELECT
      PO_Order_Id,
      SUM(invoice_amt) AS total_invoice_amt,
      SUM(sum_PO_Spend_AUD) AS total_po_amt,
    FROM X
    GROUP BY PO_Order_Id
    HAVING ABS(SUM(invoice_amt) - SUM(sum_PO_Spend_AUD)) > 0
  )

-- Step 3: Return invoice-level records for unmatched POs
SELECT
  f.Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Invoices where sum(invoice) ≠ sum(PO)' AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  f.PO_Order_Id,
  f.PO_Date,
  f.sum_PO_Spend_AUD,
  f.PO_Status,
  f.Invoice_ID AS invoice_id,
  f.Invoice_Date AS invoice_date,
  f.INV_Description AS inv_description,
  f.Invoice_Status AS invoice_status,
  f.invoice_amt AS invoice_amt,
  f.ERP_Supplier_ID,
  f.ERP_Supplier,
  'Ariba' AS System,

  -- Time buckets
  CASE
    WHEN
      CAST(f.Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM X f
JOIN PO_invoice_match_check m
  ON f.PO_Order_Id = m.PO_Order_Id
ORDER BY f.ERP_Supplier;
