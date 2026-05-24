CREATE OR REPLACE VIEW fraud.vendors_with_no_bank_account_vw
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L2, amount
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
      lfbk.BankCountryKey,
      lfbk.BankKeys,
      lfbk.BankAccountNumber,
      lfbk.AccountHolderName,
      -- CONCAT(IFNULL(lfbk.BankCountryKey, ''), '-', IFNULL(lfbk.BankKeys, ''), '-', IFNULL(lfbk.BankAccountNumber, '')) AS bank_key
      CONCAT(IFNULL(lfbk.BankKeys, ''), '-', IFNULL(lfbk.BankAccountNumber, ''))
        AS bank_key
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    LEFT JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON v.vendor = lfbk.vendor
    INNER JOIN vendors rv
      ON rv.vendor_ID = v.Vendor
    WHERE
      v.VendorStatus = 'A'
  )
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'check missing bank details for any active GNFR suppliers'
    AS routine_description,
  'Vendor with no bankacounts' AS metric_description,
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
FROM base_vendors a
WHERE bankkeys IS NULL;
