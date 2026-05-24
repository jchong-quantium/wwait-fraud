CREATE OR REPLACE view  fraud.local_vendors_missing_mandatory_fields_vw
AS
-- Local Vendor
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L2, payment_terms
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  basevendor AS (
    SELECT DISTINCT
      a.vendor AS Supplier_ID,
      a.VendorDescription AS supplier_name,
      a.DateFirstCreated AS Supplier_Creation_Date,
      Supplier_Custom_Category_L2,
      a.SearchTerm1,
      a.SearchTerm2,
      a.Street,
      a.PostalCode,
      a.City,
      a.state,
      a.country,
      a.EmailAddress,
      ad.communicationmethod,
      -- communicationmethod,
      a.TaxID,
      a.industry,
      lfbk.BankCountryKey,
      lfbk.BankKeys,
      lfbk.BankAccountNumber,
      lfbk.AccountHolderName,
      z1.ContactPersonFirstName,
      z1.ContactPersonLastName,
      z1.ContactEmail,
      c.PeriodicAccStatInd,
      c.VendorClerk,
      c.AccountingClerkTelephone,
      c.PartnerCompClerkInternet,
      OrderCurrency,
      MinorityIndicator,
      payment_terms,
      PaymentMethodSupp AS paymentmethod
    FROM
      gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v a
    LEFT JOIN vendors b
      ON a.vendor = b.vendor_ID
    LEFT JOIN
      `gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v`
        lfbk
      ON a.vendor = lfbk.vendor
    LEFT JOIN
      (
        SELECT
          Vendor, ContactPersonFirstName, ContactPersonLastName, ContactEmail
        FROM
          gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_purchorg_function_v
        WHERE ContactPerson_FunctionID = 'Z1'
      ) z1
      ON a.vendor = z1.vendor
    LEFT JOIN
      gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_lfb1_vendor_companycode_v
        c
      ON a.vendor = c.vendor
    LEFT JOIN
      gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_business_address_v ad
      ON a.AddressNumber = ad.AddressNumber
    LEFT JOIN
      gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.termsofpayment_v pay
      ON b.payment_terms = pay.TermsOfPaymentKey
    LEFT JOIN
      gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_purchorg_v p
      ON p.vendor = a.vendor
    WHERE
      a.country = 'AU'
      AND a.VendorStatus = 'A'
      AND (
        (a.VendorDescription IS NULL OR a.VendorDescription = '')
        OR (a.SearchTerm1 IS NULL OR a.SearchTerm1 = '')
        OR (a.SearchTerm2 IS NULL OR a.SearchTerm2 = '')
        OR (a.Street IS NULL OR a.Street = '')
        OR (a.PostalCode IS NULL OR a.PostalCode = '')
        OR (a.City IS NULL OR a.City = '')
        OR (a.state IS NULL OR a.state = '')
        OR (a.country IS NULL OR a.country = '')
        OR (a.EmailAddress IS NULL OR a.EmailAddress = '')
        OR (ad.communicationmethod IS NULL OR ad.communicationmethod = '')
        OR (a.TaxID IS NULL OR a.TaxID = '')
        OR (a.industry IS NULL OR a.industry = '')
        OR (lfbk.BankCountryKey IS NULL OR lfbk.BankCountryKey = '')
        OR (lfbk.BankKeys IS NULL OR lfbk.BankKeys = '')
        OR (lfbk.BankAccountNumber IS NULL OR lfbk.BankAccountNumber = '')
        OR (lfbk.AccountHolderName IS NULL OR lfbk.AccountHolderName = '')
        OR (z1.ContactPersonFirstName IS NULL OR z1.ContactPersonFirstName = '')
        OR (z1.ContactPersonLastName IS NULL OR z1.ContactPersonLastName = '')
        OR (z1.ContactEmail IS NULL OR z1.ContactEmail = '')
        OR (c.PeriodicAccStatInd IS NULL OR c.PeriodicAccStatInd = '')
        OR (c.VendorClerk IS NULL OR c.VendorClerk = '')
        OR (
          c.AccountingClerkTelephone IS NULL OR c.AccountingClerkTelephone = '')
        OR (
          c.PartnerCompClerkInternet IS NULL OR c.PartnerCompClerkInternet = '')
        OR (payment_terms IS NULL OR payment_terms = '')
        OR (PaymentMethodSupp IS NULL OR PaymentMethodSupp = '')
        OR (OrderCurrency IS NULL OR OrderCurrency = '')
        OR (MinorityIndicator IS NULL OR MinorityIndicator = ''))
    ORDER BY DateFirstCreated DESC
  )
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Other suggested from FBC report' AS routine_category,
  'Master data completeness for local vendors' AS routine_description,
  'Local Vendors Count' AS metric_description,
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
FROM basevendor
