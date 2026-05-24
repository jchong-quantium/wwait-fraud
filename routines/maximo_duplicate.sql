CREATE OR REPLACE VIEW fraud.maximo_duplicate_po_vw
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
      status,
      po_amount_gross,
      po_amount_net
    FROM `fraud.maximo_po`
    WHERE po_amount_gross <> 0 AND po_amount_gross > 10000
  ),
  dupe_groups AS (
    SELECT
      Vendor,
      Vendor_Name,
      PO_Date,
      po_amount_gross,
      COUNT(*) AS cnt,
      ARRAY_AGG(PurchasingDocumentNumber) AS po_numbers,
      DENSE_RANK()
        OVER (ORDER BY Vendor, Vendor_Name, PO_Date, po_amount_gross)
        AS group_num
    FROM base
    GROUP BY Vendor, Vendor_Name, PO_Date, po_amount_gross
    HAVING COUNT(*) > 1
  ),
  final AS (
    SELECT DISTINCT
      b.*,
      d.group_num
    FROM base b
    JOIN dupe_groups d
      ON
        b.Vendor = d.Vendor
        AND b.Vendor_Name = d.Vendor_Name
        AND b.PO_Date = d.PO_Date
        AND b.po_amount_gross = d.po_amount_gross
    ORDER BY d.group_num, b.PurchasingDocumentNumber
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
  status AS PO_Status,
  group_num AS group_number,
  Concat('Group ', CAST(group_num AS string)) AS dupe_po_group,
  'Maximo' AS system,

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
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year,
FROM final f
ORDER BY COALESCE(group_num, 999999), PO_Date, PurchasingDocumentNumber;
