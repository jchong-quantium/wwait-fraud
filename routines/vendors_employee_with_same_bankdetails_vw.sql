CREATE OR REPLACE view  fraud.vendors_employee_with_same_bankdetails_vw
AS
WITH
vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L2,amount
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
      amount,
      -- CONCAT(IFNULL(lfbk.BankCountryKey, ''), '-', IFNULL(lfbk.BankKeys, ''), '-', IFNULL(lfbk.BankAccountNumber, '')) AS bank_key
      CONCAT(IFNULL(lfbk.BankKeys, ''), '-', IFNULL(lfbk.BankAccountNumber, ''))
        AS bank_key
    FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
    INNER JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON v.vendor = lfbk.vendor
     JOIN
      vendors rv
      ON rv.vendor_ID = v.Vendor
    WHERE
      v.VendorStatus = 'A'
  )
-- ,
,
emp_bank AS (
  SELECT DISTINCT
    PGEmployeeId,
    CONCAT(  -- IFNULL(PGBANKSCountryKey, ''), '-',
      IFNULL(PGBanknumber, ''), '-', IFNULL(PPBankaccountnumber, ''))
      AS emp_bank_key
  FROM
    gcp-wow-ent-im-people-prod.adp_integrated_people_view.pr_PayrollPaymentInformation_r
)
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Scan for same bank details between vendors and employees'
    AS routine_description,
  'Vendor Count' AS metric_description,
  'Count' AS metric_unit,
  b.*,
  emp_bank.*,
  FirstName,
  LastName,
  ECFirstDayAtwork,
  ECEmploymentStatusDesc,
  ECEmployeeTypeDesc,
  ECJobTitle,
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
FROM base_vendors b
INNER JOIN emp_bank
  ON b.bank_key = emp_bank.emp_bank_key
LEFT JOIN gcp-wow-risk-de-data-prod.Employee.Dim_Employee_Central emp
  ON emp_bank.PGEmployeeId = emp.ECEmployeeID;