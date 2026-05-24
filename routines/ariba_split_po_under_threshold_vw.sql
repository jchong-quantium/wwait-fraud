CREATE OR REPLACE VIEW `fraud.ariba_split_po_under_threshold_vw`
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L2
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  Filtered_POs AS (
    SELECT DISTINCT
      PO_Number,
      Requisition_ID,
      PO_Date,
      Vendor_Number,
      Vendor_Description,
      PO_Amount_Invoiced,
      PO_Spend,
      PO_Status,
      PO_Title as PO_Description,
      Contract_Id,
      Requestor,
      Approver,
      Supplier_Custom_Category_L2
    FROM fraud.ariba_po_invoice
    --   AND ar_po.sum_Amount_Invoiced < 50000  -- POs individually under $50K
  ),
  Grouped_POs AS (
    SELECT
      Vendor_Number,
      Vendor_Description,
      PO_Date,
      Supplier_Custom_Category_L2,
      COUNT(PO_Number) AS PO_Count,
      SUM(PO_Spend) AS Total_PO_Amount
    FROM Filtered_POs
    GROUP BY
      Vendor_Number, Vendor_Description, PO_Date, Supplier_Custom_Category_L2
    HAVING
      COUNT(PO_Number) > 1
      AND SUM(PO_Amount_Invoiced) >= 50000
  ),

  -- Join to bring individual PO details, assign group numbers
  POs_With_Groups AS (
    SELECT
      f.Vendor_Number,
      f.Vendor_Description,
      f.Supplier_Custom_Category_L2,
      f.PO_Date,
      f.PO_Number,
      f.PO_Amount_Invoiced,
      DENSE_RANK() OVER (ORDER BY g.Vendor_Number, g.PO_Date) AS Group_ID
    FROM Filtered_POs f
    JOIN Grouped_POs g
      ON f.Vendor_Number = g.Vendor_Number AND f.PO_Date = g.PO_Date
  ),
  final_data AS (
    SELECT
      Vendor_Number,
      Vendor_Description,
      PO_Date,
      Supplier_Custom_Category_L2,
      COUNT(PO_Number) OVER (PARTITION BY Vendor_Number, PO_Date) AS PO_Count,
      SUM(PO_Amount_Invoiced)
        OVER (PARTITION BY Vendor_Number, PO_Date) AS Total_PO_Amount,
      PO_Number,
      PO_Amount_Invoiced AS PO_Individual_Amount,
      Group_ID,
      CONCAT('Group ', Group_ID) AS SplitPO_Group
    FROM POs_With_Groups
    ORDER BY Vendor_Number, PO_Date, Group_ID
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Detect potential PO splitting by identifying multiple POs raised by the same vendor on the same day where the combined total exceeds the threshold of $50,000. '
    AS routine_description,
  'PO Count' AS metric_description,
  'Count' AS metric_unit,
  final_data.* EXCEPT (PO_Count, Supplier_Custom_Category_L2),
  'Ariba' AS system,
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
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM final_data
ORDER BY Group_ID ASC;
