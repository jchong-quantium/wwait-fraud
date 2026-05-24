CREATE OR REPLACE VIEW `fraud.ariba_open_po_vw`
AS
WITH
  Y AS (
    SELECT DISTINCT
      PO_Number,
      Requisition_ID,
      PO_Date,
      PO_Title AS PO_description,
      Vendor_Number,
      Vendor_Description,
      Supplier_Custom_Category_L2,
      PO_Spend,
      PO_Status,
      PO_Amount_Invoiced
    FROM fraud.ariba_po_invoice
    WHERE
      PO_Status NOT IN ('Confirmed', 'Received', 'Rejected')
      AND DATE_DIFF(CURRENT_DATE(), Po_date, DAY) > 30
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Procurement' AS routine_category,
  'Ariba - Scan for aged open purchase orders i.e. > x days from purchase order date'
    AS routine_description,
  'PO Count' AS metric_description,
  'Count' AS metric_unit,
  PO_Number,
  PO_Date,
  PO_Description,
  PO_Status,
  Vendor_Number,
  Vendor_Description,
  PO_Spend,
  PO_Amount_Invoiced,
  'Ariba' AS system,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(PO_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(PO_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(PO_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(PO_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(PO_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(PO_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM Y
WHERE PO_Spend > 1
ORDER BY PO_Date ASC;