CREATE OR REPLACE VIEW fraud.sap_multiple_payments_same_vendor_vw
AS
WITH
  Payment_Counts AS (
    SELECT DISTINCT
      D_Vendor,
      vendor_name,
      Payment_Date_Woolies AS Payment_Date_Woolworths,
      COUNT(*) AS Payment_Count,
    FROM fraud.base_payment
    GROUP BY D_Vendor, Payment_Date_Woolies, vendor_name
    HAVING COUNT(*) > 1
  ),
  payment_1 AS (
    SELECT
      bp.*,
      DENSE_RANK()
        OVER (ORDER BY bp.D_Vendor, Payment_Date_Woolies) AS Payment_Group
    FROM fraud.base_payment bp
    JOIN Payment_Counts pc
      ON
        bp.D_Vendor = pc.D_Vendor
        AND bp.Payment_Date_Woolies = pc.Payment_Date_Woolworths
    ORDER BY bp.D_Vendor, bp.Payment_Date_Woolies
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_Area,
  'Payments' AS routine_category,
  'SAP - Scan for multiple payments to same vendor on same date.'
    AS routine_description,
  'Payment Count' AS metric_description,
  'Count' AS metric_unit,
  f.D_Vendor AS Vendor,
  vendor_name,
  CAST(Payment_Date_Woolies AS date) AS Payment_Date_Woolworths,
  CAST(Payment_Date_Appears_In_Vendor_Account AS date)
    AS Payment_Date_Appears_In_Vendor_Account,
  Payment_Clearing_Doc,
  Payment_Amount,
  Payment_Group,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM Payment_1 f
ORDER BY
  D_Vendor,
  Vendor_Name,
  Payment_Date_Woolworths;
