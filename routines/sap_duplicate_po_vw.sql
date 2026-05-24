---SAP
CREATE OR REPLACE view  fraud.sap_duplicate_po_vw
AS
WITH
  base AS (
    SELECT
      PurchasingDocumentNumber,
      Vendor,
      Vendor_Name,
      DATE(PurchasingDocumentDate) AS PO_Date,
      Supplier_Custom_Category_L2,
      DocumentLastChangedOn,
      PurchasingItemShortText,
      DocumentCurrency,
      po_amount_gross,
      po_amount_net
    FROM `gcp-wow-risk-de-data-prod.fraud.sap_po`
    WHERE
      po_amount_gross > 10000
      AND vendor NOT IN (
        '0096023037', '0098106654', '0096012023', '0053406001', '0071043001',
        '0073499001', '0098102853', '0076017001')
  ),

  -- Step 1: Find all pairs that qualify as duplicates
  pairs AS (
    SELECT DISTINCT
      LEAST(a.PurchasingDocumentNumber, b.PurchasingDocumentNumber) AS po_min,
      GREATEST(a.PurchasingDocumentNumber, b.PurchasingDocumentNumber) AS po_max
    FROM base a
    JOIN base b
      ON
        a.Vendor = b.Vendor
        AND a.po_amount_gross = b.po_amount_gross
        AND a.PurchasingDocumentNumber <> b.PurchasingDocumentNumber
        AND ABS(DATE_DIFF(a.PO_Date, b.PO_Date, DAY)) <= 3
  ),

  -- Step 2: Create a group number using connected components logic
  grouped AS (
    SELECT
      po_min AS PO_Number,
      DENSE_RANK() OVER (ORDER BY po_min) AS group_id
    FROM pairs
    UNION DISTINCT
    SELECT
      po_max AS PO_Number,
      DENSE_RANK() OVER (ORDER BY po_min) AS group_id
    FROM pairs
  ),

  -- Step 3: Attach group numbers to the base table
  final AS (
    SELECT
      b.*,
      g.group_id
    FROM base b
    LEFT JOIN grouped g
      ON b.PurchasingDocumentNumber = g.PO_Number
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Procurement' AS routine_category,
  'Duplicate POs having same amount, same vendor raised in a span of 0-3 days'
    AS routine_description,
  'Duplicate PO' AS metric_description,
  'Count' AS metric_unit,
  PurchasingDocumentNumber AS PO_Number,
  PO_Date,
  PurchasingItemShortText AS PO_Description,
  vendor AS Vendor_Number,
  Vendor_Name AS Vendor_Description,
  po_amount_gross AS PO_Spend,
  '' AS PO_Status,
  group_id AS group_number,
  Concat('Group ', CAST(group_id AS string)) AS dupe_po_group,
  'SAP' AS system,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM final f
WHERE group_id IS NOT NULL
ORDER BY COALESCE(group_id, 999999), PO_Date, PurchasingDocumentNumber;
