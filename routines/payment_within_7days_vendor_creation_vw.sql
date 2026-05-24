CREATE OR REPLACE VIEW fraud.payment_within_7days_vendor_creation_vw
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
  base AS (
    SELECT DISTINCT
      v.Vendor AS Supplier_ID,
      v.VendorDescription AS Supplier_Name,
      TRIM(v.TaxID) AS ABN,
      v.DateFirstCreated AS Supplier_Creation_Date,
      rv.Supplier_Custom_Category_L2,
      CAST(Payment_Date_Woolies AS date) Payment_Date_Woolies
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    INNER JOIN vendors rv
      ON rv.vendor_ID = v.Vendor
    JOIN fraud.base_payment b
      ON
        v.Vendor = b.D_Vendor
        AND CAST(Payment_Date_Woolies AS date)
          BETWEEN v.DateFirstCreated
          AND DATE_ADD(v.DateFirstCreated, INTERVAL 7 DAY)
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Scan for payments done within 7 days of Vendor Creation'
    AS routine_description,
  'Vendor Count' AS metric_description,
  'Count' AS metric_unit,
  *,
  CASE
    WHEN
      CAST(Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM base
