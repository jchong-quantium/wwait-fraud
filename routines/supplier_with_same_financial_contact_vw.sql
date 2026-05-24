CREATE OR REPLACE VIEW fraud.supplier_with_same_financial_contact_vw
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
  base_vendors AS (
    SELECT DISTINCT
      v.Vendor AS Supplier_ID,
      v.VendorDescription AS Supplier_Name,
      TRIM(v.TaxID) AS ABN,
      v.DateFirstCreated AS Supplier_Creation_Date,
      Supplier_Custom_Category_L2,
      v.BuildingNumber,
      v.Street,
      v.City,
      v.PostalCode,
      v.State,
      v.Country,
      LOWER(
        TRIM(
          CONCAT(
            v.BuildingNumber,
            ' ',
            v.Street,
            ' ',
            v.City,
            ' ',
            v.PostalCode,
            ' ',
            v.State,
            ' ',
            v.Country))) AS full_address,
      FinancialPartyContactName
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    INNER JOIN vendors rv
      ON rv.vendor_ID = v.Vendor
  ),
  grp AS (
    SELECT
      FinancialPartyContactName,
      COUNT(*) vendor_cnt,
      DENSE_RANK() OVER (ORDER BY FinancialPartyContactName) AS group_number
    FROM base_vendors
    GROUP BY 1
    HAVING COUNT(*) > 1
  )
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Vendor Profile' AS routine_category,
  'Suppliers with same financial contact' AS routine_description,
  'Vendor Count' AS metric_description,
  'Count' AS metric_unit,
  a.* EXCEPT (financialpartycontactname),
  b.*,
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
# Supplier_ID,Supplier_Name,street,city
FROM base_vendors a
JOIN grp b
  ON
    a.FinancialPartyContactName = b.FinancialPartyContactName
-- where Supplier_Name='Beacon Real Estate Pty Ltd'
