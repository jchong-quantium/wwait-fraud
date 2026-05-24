CREATE OR REPLACE VIEW fraud.one_time_vendor_payment_vw
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
  vendor_payment AS (
    SELECT
      v.Vendor AS Supplier_ID,
      v.VendorDescription AS Supplier_Name,
      v.VendorStatus AS vendor_status,
      TRIM(v.TaxID) AS ABN,
      v.DateFirstCreated AS Supplier_Creation_Date,
      rv.Supplier_Custom_Category_L2,
      v.BuildingNumber,
      v.Street,
      v.City,
      v.PostalCode,
      v.State,
      v.Country,
      Payment_Date_Woolies,
      Payment_Amount
    FROM fraud.base_payment b
    JOIN `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
      ON v.vendor = b.D_Vendor
    INNER JOIN vendors rv
      ON
        rv.vendor_ID = v.Vendor
    -- and v.VendorStatus = 'A'
  ),
  vendor_grouped AS (
    SELECT Supplier_ID, COUNT(*)
    FROM vendor_payment
    GROUP BY 1
    HAVING COUNT(*) = 1
  )
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'One time Vendor payment over 50000AUD' AS routine_description,
  'Vendor Count' AS metric_description,
  'Count' AS metric_unit,
  b.*,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM vendor_grouped a
JOIN vendor_payment b
  ON a.supplier_id = b.supplier_id
WHERE payment_amount > 50000;
