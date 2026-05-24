CREATE OR REPLACE view `fraud.sap_split_po_under_threshold_vw`
AS
WITH
  Cleaned_Data AS (
    SELECT DISTINCT
      PurchasingDocumentNumber AS PO_Number,
      PurchasingDocumentDate AS PO_Date,
      Vendor AS Vendor_Number,
      Vendor_Name AS Vendor_Description,
      po_amount_net AS PO_Amount,
      PurchasingItemShortText AS PO_Description,
      'SAP' AS Purchasing_System,
      supplier_Custom_Category_L2
    FROM `fraud.sap_po`
    -- WHERE PO_Amount >= 50000  -- POs at or above the threshold
  ),
  Grouped_POs AS (
    SELECT
      Vendor_Number,
      Vendor_Description,
      PO_Date,
      COUNT(DISTINCT PO_Number) AS PO_Count,
      SUM(PO_Amount) AS Total_PO_Amount
    FROM Cleaned_Data
    GROUP BY Vendor_Number, Vendor_Description, PO_Date
    HAVING
      COUNT(DISTINCT PO_Number) > 1
      AND SUM(PO_Amount) >= 50000
  ),
  POs_With_Groups AS (
    SELECT
      c.*,
      ROW_NUMBER()
        OVER (PARTITION BY g.Vendor_Number, g.PO_Date ORDER BY c.PO_Number)
        AS Row_Num,
      DENSE_RANK() OVER (ORDER BY g.Vendor_Number, g.PO_Date) AS Group_ID
    FROM Cleaned_Data c
    JOIN Grouped_POs g
      ON
        c.Vendor_Number = g.Vendor_Number
        AND c.PO_Date = g.PO_Date
  ),
  final_data AS (
    SELECT
      Vendor_Number,
      Vendor_Description,
      PO_Date,
      PO_Number,
      PO_Amount AS PO_Individual_Amount,
      PO_Description,
      Purchasing_System,
      supplier_Custom_Category_L2,
      Group_ID,
      -- COUNT(PO_Number) OVER (PARTITION BY Vendor_Number, PO_Date) AS PO_Count,
      SUM(PO_Amount)
        OVER (PARTITION BY Vendor_Number, PO_Date) AS Total_PO_Amount,
      CONCAT('Group ', Group_ID) AS SplitPO_Group
    FROM POs_With_Groups
    ORDER BY Vendor_Number, PO_Date, PO_Number
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Detect potential PO splitting by identifying multiple POs raised by the same vendor on the same day where the combined total exceeds the threshold of $50,000. '
    AS routine_description,
  'PO Count' AS metric_description,
  'Count' AS metric_unit,
  Vendor_Number,
  Vendor_Description,
  PO_Date,
  Total_PO_Amount,
  PO_Number,
  PO_Individual_Amount,
  Group_ID,
  SplitPO_Group,
  Purchasing_System AS system,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM final_data
ORDER BY Group_ID ASC;