CREATE OR REPLACE view fraud.approved_blocked_vendor_check_vw
AS
WITH
  base_Approved_vendors AS (
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
      CONCAT(
        IFNULL(lfbk.BankCountryKey, ''),
        '-',
        IFNULL(lfbk.BankKeys, ''),
        '-',
        IFNULL(lfbk.BankAccountNumber, '')) AS bank_key
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    INNER JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON v.vendor = lfbk.vendor
    INNER JOIN
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        rv
      ON rv.vendor_ID = v.Vendor
    WHERE
      -- Supplier_Custom_Category_L2 LIKE 'Facilities Management Services'
      company_code = '1000'
      AND v.VendorStatus = 'A'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  base_Blocked_vendors AS (
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
      CONCAT(
        IFNULL(lfbk.BankCountryKey, ''),
        '-',
        IFNULL(lfbk.BankKeys, ''),
        '-',
        IFNULL(lfbk.BankAccountNumber, '')) AS bank_key
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    INNER JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON v.vendor = lfbk.vendor
    INNER JOIN
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        rv
      ON rv.vendor_ID = v.Vendor
    -- WHERE Supplier_Custom_Category_L2 LIKE 'Facilities Management Services'
    WHERE
      company_code = '1000'
      AND v.VendorStatus <> 'A'
      AND ifnull(v.VendorStatus, '') <> ''
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  matched_blocked_vendors AS (
    SELECT
      i.Supplier_ID AS Blocked_Supplier_ID,
      i.Supplier_Name AS Blocked_Supplier_Name,
      i.full_address AS Blocked_Address,
      i.bank_key AS Blocked_Bank_Key,
      i.ABN AS Blocked_ABN,
      i.Supplier_Creation_Date AS Blocked_Vendor_Creation_Date,
      i.Supplier_Custom_Category_L2 AS Blocked_Supplier_Custom_Category_L2,
      a.Supplier_ID AS Approved_Supplier_ID,
      a.Supplier_Name AS Approved_Supplier_Name,
      a.full_address AS Approved_Address,
      a.bank_key AS Approved_Bank_Key,
      a.ABN AS Approved_ABN,
      a.Supplier_Creation_Date AS Approved_Vendor_Creation_Date,
      a.Supplier_Custom_Category_L2 AS Approved_Supplier_Custom_Category_L2,
      CASE
        WHEN i.bank_key = a.bank_key AND i.full_address = a.full_address
          THEN 'Exact match: Bank and Address'
        WHEN i.bank_key = a.bank_key THEN 'Exact match: Bank only'
        WHEN i.full_address = a.full_address THEN 'Exact match: Address only'
        WHEN i.ABN = a.ABN THEN 'Exact match: ABN only'
        WHEN
          `gcp-wow-risk-de-data-prod.fraud.levenshtein_distance`(
            i.full_address, a.full_address)
          <= 5
          THEN 'Similar address'
        ELSE NULL
        END AS match_reason
    FROM base_Blocked_vendors i
    JOIN base_Approved_vendors a
      ON
        i.bank_key = a.bank_key
        OR i.full_address = a.full_address
        OR i.ABN = a.ABN
        OR `gcp-wow-risk-de-data-prod.fraud.levenshtein_distance`(
          i.full_address, a.full_address)
          <= 5
  ),
  matched_only AS (
    SELECT *
    FROM matched_Blocked_vendors
    WHERE match_reason IS NOT NULL
  )
SELECT DISTINCT
  Approved_Supplier_Custom_Category_L2 AS Approved_vendor_area,
  Blocked_Supplier_Custom_Category_L2 AS Blocked_vendor_area,
  'Payments' AS routine_category,
  'Scan for blocked vendors sharing same address and bank details as approved vendors.'
    AS routine_description,
  'Duplicate Vendors' AS metric_description,
  'Count' AS metric_unit,
  f.*,
  Concat(
    'Group ',
    CAST(DENSE_RANK() OVER (ORDER BY concat(Approved_Supplier_ID)) AS string))
    AS new_group_number,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Approved_Vendor_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Approved_Vendor_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Approved_Vendor_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Approved_Vendor_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Approved_Vendor_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Approved_Vendor_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year,
FROM matched_only f
ORDER BY Approved_Supplier_ID;
