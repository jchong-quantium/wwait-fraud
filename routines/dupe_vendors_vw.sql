CREATE OR REPLACE VIEW fraud.dupe_vendors_vw
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
    INNER JOIN vendors r
      ON r.vendor_ID = v.Vendor
    WHERE v.VendorStatus = 'A'
  ),

  -- 1️⃣ ABN DUPES
  abn_dupes AS (
    SELECT ABN
    FROM base_vendors
    WHERE ABN IS NOT NULL AND ABN != ''
    GROUP BY ABN
    HAVING COUNT(*) > 1
  ),
  abn_grouped AS (
    SELECT
      *,
      DENSE_RANK() OVER (ORDER BY ABN) AS group_number
    FROM base_vendors
    WHERE ABN IN (SELECT ABN FROM abn_dupes)
  ),

  -- 2️⃣ ADDRESS DUPES
  address_dupes AS (
    SELECT full_address
    FROM base_vendors
    WHERE full_address IS NOT NULL AND full_address != ''
    GROUP BY full_address
    HAVING COUNT(*) > 1
  ),
  address_grouped AS (
    SELECT
      *,
      DENSE_RANK() OVER (ORDER BY full_address) AS group_number
    FROM base_vendors
    WHERE full_address IN (SELECT full_address FROM address_dupes)
  ),

  -- 3️⃣ BANK DUPES
  bank_dupes AS (
    SELECT bank_key
    FROM base_vendors
    WHERE bank_key IS NOT NULL AND bank_key != '' AND bank_key NOT LIKE '--'
    GROUP BY bank_key
    HAVING COUNT(*) > 1
  ),
  bank_grouped AS (
    SELECT
      *,
      DENSE_RANK() OVER (ORDER BY bank_key) AS group_number
    FROM base_vendors
    WHERE bank_key IN (SELECT bank_key FROM bank_dupes)
  ),

  -- 🔁 FINAL COMBINED OUTPUT
  final_combined AS (
    SELECT DISTINCT
      Supplier_ID,
      Supplier_Name,
      Supplier_Creation_Date,
      ABN,
      full_address,
      BankCountryKey,
      BankKeys,
      BankAccountNumber,
      AccountHolderName,
      'ABN dupe' AS duplicate_reason,
      group_number,
      Supplier_Custom_Category_L2,
      CONCAT('group ', CAST(group_number AS STRING)) AS duplicate_group,
      'Yes' AS is_duplicate
    FROM abn_grouped
    UNION ALL
    SELECT DISTINCT
      Supplier_ID,
      Supplier_Name,
      Supplier_Creation_Date,
      ABN,
      full_address,
      BankCountryKey,
      BankKeys,
      BankAccountNumber,
      AccountHolderName,
      'Address dupe' AS duplicate_reason,
      group_number,
      Supplier_Custom_Category_L2,
      CONCAT('group ', CAST(group_number AS STRING)) AS duplicate_group,
      'Yes' AS is_duplicate
    FROM address_grouped
    UNION ALL
    SELECT DISTINCT
      Supplier_ID,
      Supplier_Name,
      Supplier_Creation_Date,
      ABN,
      full_address,
      BankCountryKey,
      BankKeys,
      BankAccountNumber,
      AccountHolderName,
      'Bank dupe' AS duplicate_reason,
      group_number,
      Supplier_Custom_Category_L2,
      CONCAT('group ', CAST(group_number AS STRING)) AS duplicate_group,
      'Yes' AS is_duplicate
    FROM bank_grouped
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Scan for duplicate vendors e.g. same address, same bank details,same ABN or address'
    AS routine_description,
  'Duplicate Vendors' AS metric_description,
  'Count' AS metric_unit,
  f.*,
  DENSE_RANK()
    OVER (ORDER BY concat(Supplier_ID, duplicate_reason, group_number))
    AS new_group_number,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM final_combined f
ORDER BY duplicate_reason, group_number;
