CREATE OR REPLACE VIEW fraud.blocked_vendors_reonboarded_vw
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
  blocked_vendor AS (
    SELECT DISTINCT
      v.Vendor AS Supplier_ID,
      v.VendorDescription AS Supplier_Name,
      TRIM(v.TaxID) AS blocked_Supplier_ABN,
      v.DateFirstCreated AS blocked_Supplier_Creation_Date,
      Supplier_Custom_Category_L2 AS blocked_Supplier_Custom_Category_L2,
      FinancialPartyContactName,
      EmailAddress,
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
      TelephoneNumber AS blocked_TelephoneNumber,
      lfbk.BankKeys AS blocked_BSB,
      lfbk.BankAccountNumber AS blocked_AccountNumber
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON v.vendor = lfbk.vendor
    JOIN vendors r
      ON v.Vendor = r.vendor_ID
    WHERE
      v.VendorStatus <> 'A'
      AND v.VendorStatus IS NOT NULL
      AND v.VendorStatus <> ''
  ),
  Approved_vendor AS (
    SELECT DISTINCT
      v.Vendor AS Approved_Supplier_ID,
      v.VendorDescription AS Approved_Supplier_Name,
      v.DateFirstCreated AS Approved_Supplier_Creation_Date,
      Supplier_Custom_Category_L2 AS Approved_Supplier_Custom_Category_L2,
      TRIM(v.TaxID) AS Approved_ABN,
      FinancialPartyContactName AS Approved_FinancialPartyContactName,
      EmailAddress AS Approved_EmailAddress,
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
            v.Country))) AS Approved_full_address,
      TelephoneNumber AS Approved_TelephoneNumber,
      lfbk.BankKeys AS Approved_BSB,
      lfbk.BankAccountNumber AS Approved_AccountNumber
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON v.vendor = lfbk.vendor
    JOIN vendors r
      ON r.Vendor_ID = v.Vendor
    WHERE v.VendorStatus = 'A'
  ),
  matches AS (

    -- Match 1: BSB + Account Number
    SELECT
      i.Supplier_ID AS blocked_Supplier_Id,
      i.Supplier_Name AS blocked_Supplier_Name,
      a.Approved_Supplier_ID,
      a.Approved_Supplier_Name,
      a.Approved_Supplier_Creation_Date,
      a.Approved_Supplier_Custom_Category_L2,
      i.blocked_BSB,
      a.Approved_BSB,
      i.blocked_AccountNumber,
      a.Approved_AccountNumber,
      i.blocked_TelephoneNumber,
      a.Approved_TelephoneNumber,
      i.EmailAddress AS blocked_EmailAddress,
      a.Approved_EmailAddress,
      i.blocked_Supplier_ABN,
      a.Approved_ABN,
      i.full_address AS blocked_full_address,
      a.Approved_full_address,
      i.FinancialPartyContactName AS blocked_FinancialPartyContactName,
      a.Approved_FinancialPartyContactName,
      'Matched on BSB + Account Number' AS match_reason
    FROM blocked_vendor i
    JOIN Approved_vendor a
      ON
        i.blocked_BSB = a.Approved_BSB
        AND i.blocked_AccountNumber = a.Approved_AccountNumber
    WHERE i.Supplier_ID != a.Approved_Supplier_ID
    UNION ALL

    -- Match 2: Email
    SELECT
      i.Supplier_ID AS blocked_Supplier_Id,
      i.Supplier_Name AS blocked_Supplier_Name,
      a.Approved_Supplier_ID,
      a.Approved_Supplier_Name,
      a.Approved_Supplier_Creation_Date,
      a.Approved_Supplier_Custom_Category_L2,
      i.blocked_BSB,
      a.Approved_BSB,
      i.blocked_AccountNumber,
      a.Approved_AccountNumber,
      i.blocked_TelephoneNumber,
      a.Approved_TelephoneNumber,
      i.EmailAddress AS blocked_EmailAddress,
      a.Approved_EmailAddress,
      i.blocked_Supplier_ABN,
      a.Approved_ABN,
      i.full_address AS blocked_full_address,
      a.Approved_full_address,
      i.FinancialPartyContactName AS blocked_FinancialPartyContactName,
      a.Approved_FinancialPartyContactName,
      'Matched on Email' AS match_reason
    FROM blocked_vendor i
    JOIN Approved_vendor a
      ON i.EmailAddress = a.Approved_EmailAddress
    WHERE
      i.Supplier_ID != a.Approved_Supplier_ID
      AND IFNULL(i.EmailAddress, '') <> ''
    UNION ALL

    -- Match 3: Phone Number
    SELECT
      i.Supplier_ID AS blocked_Supplier_Id,
      i.Supplier_Name AS blocked_Supplier_Name,
      a.Approved_Supplier_ID,
      a.Approved_Supplier_Name,
      a.Approved_Supplier_Creation_Date,
      a.Approved_Supplier_Custom_Category_L2,
      i.blocked_BSB,
      a.Approved_BSB,
      i.blocked_AccountNumber,
      a.Approved_AccountNumber,
      i.blocked_TelephoneNumber,
      a.Approved_TelephoneNumber,
      i.EmailAddress AS blocked_EmailAddress,
      a.Approved_EmailAddress,
      i.blocked_Supplier_ABN,
      a.Approved_ABN,
      i.full_address AS blocked_full_address,
      a.Approved_full_address,
      i.FinancialPartyContactName AS blocked_FinancialPartyContactName,
      a.Approved_FinancialPartyContactName,
      'Matched on Phone Number' AS match_reason
    FROM blocked_vendor i
    JOIN Approved_vendor a
      ON
        REGEXP_REPLACE(IFNULL(i.blocked_TelephoneNumber, ''), r'[^0-9]', '')
        = REGEXP_REPLACE(IFNULL(a.Approved_TelephoneNumber, ''), r'[^0-9]', '')
    WHERE
      i.Supplier_ID != a.Approved_Supplier_ID
      AND IFNULL(i.blocked_TelephoneNumber, '') NOT IN ('', 'N/A')
    UNION ALL

    -- Match 4: ABN
    SELECT
      i.Supplier_ID AS blocked_Supplier_Id,
      i.Supplier_Name AS blocked_Supplier_Name,
      a.Approved_Supplier_ID,
      a.Approved_Supplier_Name,
      a.Approved_Supplier_Creation_Date,
      a.Approved_Supplier_Custom_Category_L2,
      i.blocked_BSB,
      a.Approved_BSB,
      i.blocked_AccountNumber,
      a.Approved_AccountNumber,
      i.blocked_TelephoneNumber,
      a.Approved_TelephoneNumber,
      i.EmailAddress AS blocked_EmailAddress,
      a.Approved_EmailAddress,
      i.blocked_Supplier_ABN,
      a.Approved_ABN,
      i.full_address AS blocked_full_address,
      a.Approved_full_address,
      i.FinancialPartyContactName AS blocked_FinancialPartyContactName,
      a.Approved_FinancialPartyContactName,
      'Matched on ABN' AS match_reason
    FROM blocked_vendor i
    JOIN Approved_vendor a
      ON i.blocked_Supplier_ABN = a.Approved_ABN
    WHERE
      i.Supplier_ID != a.Approved_Supplier_ID
      AND IFNULL(i.blocked_Supplier_ABN, '') <> ''
    UNION ALL

    -- Match 5: Address (exact match, cleaned)
    SELECT
      i.Supplier_ID AS blocked_Supplier_Id,
      i.Supplier_Name AS blocked_Supplier_Name,
      a.Approved_Supplier_ID,
      a.Approved_Supplier_Name,
      a.Approved_Supplier_Creation_Date,
      a.Approved_Supplier_Custom_Category_L2,
      i.blocked_BSB,
      a.Approved_BSB,
      i.blocked_AccountNumber,
      a.Approved_AccountNumber,
      i.blocked_TelephoneNumber,
      a.Approved_TelephoneNumber,
      i.EmailAddress AS blocked_EmailAddress,
      a.Approved_EmailAddress,
      i.blocked_Supplier_ABN,
      a.Approved_ABN,
      i.full_address AS blocked_full_address,
      a.Approved_full_address,
      i.FinancialPartyContactName AS blocked_FinancialPartyContactName,
      a.Approved_FinancialPartyContactName,
      'Matched on Address' AS match_reason
    FROM blocked_vendor i
    JOIN Approved_vendor a
      ON
        REGEXP_REPLACE(LOWER(TRIM(i.full_address)), r'[^a-z0-9]', '')
        = REGEXP_REPLACE(LOWER(TRIM(a.Approved_full_address)), r'[^a-z0-9]', '')
    WHERE
      i.Supplier_ID != a.Approved_Supplier_ID
      AND IFNULL(i.full_address, '') <> ''
    UNION ALL

    -- Match 6: Financial Party Contact Name
    SELECT
      i.Supplier_ID AS blocked_Supplier_Id,
      i.Supplier_Name AS blocked_Supplier_Name,
      a.Approved_Supplier_ID,
      a.Approved_Supplier_Name,
      a.Approved_Supplier_Creation_Date,
      a.Approved_Supplier_Custom_Category_L2,
      i.blocked_BSB,
      a.Approved_BSB,
      i.blocked_AccountNumber,
      a.Approved_AccountNumber,
      i.blocked_TelephoneNumber,
      a.Approved_TelephoneNumber,
      i.EmailAddress AS blocked_EmailAddress,
      a.Approved_EmailAddress,
      i.blocked_Supplier_ABN,
      a.Approved_ABN,
      i.full_address AS blocked_full_address,
      a.Approved_full_address,
      i.FinancialPartyContactName AS blocked_FinancialPartyContactName,
      a.Approved_FinancialPartyContactName,
      'Matched on Financial Party Contact Name' AS match_reason
    FROM blocked_vendor i
    JOIN Approved_vendor a
      ON i.FinancialPartyContactName = a.Approved_FinancialPartyContactName
    WHERE
      i.Supplier_ID != a.Approved_Supplier_ID
      AND IFNULL(i.FinancialPartyContactName, '') <> ''
  )
SELECT DISTINCT
  Approved_Supplier_Custom_Category_L2 AS vendor_area,
  'Vendor Profile' AS routine_category,
  'Detect if previously banned vendors are re-onboarded using similar details'
    AS routine_description,
  'Vendor Count' AS metric_description,
  'Count' AS metric_unit,
  f.*,
  Concat(
    'Group ',
    CAST(DENSE_RANK() OVER (ORDER BY concat(Approved_Supplier_ID)) AS string))
    AS new_group_number,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Approved_Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Approved_Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Approved_Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Approved_Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Approved_Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Approved_Supplier_Creation_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM matches f
ORDER BY Approved_Supplier_ID;
