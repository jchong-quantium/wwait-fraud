CREATE OR REPLACE view fraud.ariba_invoices_before_po_vw
AS
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Invoices dated before their matched PO dates' AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  f.PO_Order_Id,
  f.PO_Date,
  PO_Spend AS sum_PO_Spend_AUD,
  PO_Status,
  f.Invoice_ID AS invoice_id,
  f.Invoice_Date AS invoice_date,
  f.INV_Description AS inv_description,
  f.Invoice_Status AS invoice_status,
  f.amount_invoiced AS invoice_amt,
  f.Vendor_Number AS ERP_Supplier_ID,
  f.Vendor_Description AS ERP_Supplier,
  'Ariba' AS System,

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
FROM fraud.ariba_po_invoice f
WHERE f.Invoice_Date <= f.PO_Date
ORDER BY f.Vendor_Number;
