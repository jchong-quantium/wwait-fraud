CREATE OR REPLACE VIEW fraud.sap_payments_on_weekends_or_holidays_vw
AS
WITH
  base AS (
    SELECT
      *,
      CAST(Payment_Date_Woolies AS date) AS payment_date_parsed
    FROM gcp-wow-risk-de-data-prod.fraud.base_payment
  ),
  public_holidays AS (
    SELECT DISTINCT eventname, eventstartdate AS holiday_date
    FROM
      gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_gsheet_events_and_holidays_v
    WHERE
      eventtype = 'Public Holiday'
      AND eventstartdate
        BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 24 Month)
        AND CURRENT_DATE()
  ),
  flagged_payments AS (
    SELECT
      base.*,

      -- Flag for weekend
      CASE
        WHEN EXTRACT(DAYOFWEEK FROM payment_date_parsed) IN (1, 7) THEN 'Y'
        ELSE 'N'
        END AS is_weekend,

      -- Flag for public holiday
      CASE
        WHEN ph.holiday_date IS NOT NULL THEN 'Y'
        ELSE 'N'
        END AS is_public_holiday
    FROM base
    LEFT JOIN public_holidays ph
      ON ph.holiday_date = base.payment_date_parsed
  ),
  filtered_data AS (
    SELECT *
    FROM flagged_payments
    WHERE is_weekend = 'Y' OR is_public_holiday = 'Y'
    ORDER BY D_Vendor, Payment_Date_Woolies
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_Area,
  'Payments' AS routine_category,
  'SAP - Scan for payments made on weekends and public holidays.'
    AS routine_description,
  'Payment Count' AS metric_description,
  'Count' AS metric_unit,
  f.D_Vendor AS Vendor,
  Vendor_Name,
  CAST(Payment_Date_Woolies AS date) AS Payment_Date_Woolworths,
  CAST(Payment_Date_Appears_In_Vendor_Account AS date)
    AS Payment_Date_Appears_In_Vendor_Account,
  Payment_Clearing_Doc,
  Payment_Amount,
  is_weekend,
  is_public_holiday,

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
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM filtered_data f
ORDER BY D_Vendor, Payment_Date_Woolworths;
