CREATE OR REPLACE VIEW fraud.sap_payment_blocked_vendor_vw
AS
WITH
  vendor_pay_status AS (
    SELECT
      bp.*,
      CASE
        WHEN v.VendorStatus = 'B' THEN 'Block- applied for Payments'
        WHEN v.vendorstatus = 'C' THEN 'Block -applied to Purchase/Procurement'
        WHEN ifnull(v.VendorStatus, '') = '' THEN 'No Response'
        END AS VendorStatus,
      DateFirstCreated,
      DateLastChanged
    FROM gcp-wow-risk-de-data-prod.fraud.base_payment bp
    INNER JOIN `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
      ON bp.D_Vendor = v.Vendor
    WHERE v.VendorStatus <> 'A'
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS Vendor_Area,
  'Payments' AS routine_category,
  'SAP - Scan for Payments on Blocked Vendor Accounts' AS routine_description,
  'Vendor Count' AS metric_description,
  'Count' AS metric_unit,
  f.*,

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
FROM vendor_pay_status f
ORDER BY D_Vendor;
