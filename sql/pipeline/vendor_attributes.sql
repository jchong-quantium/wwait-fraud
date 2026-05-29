CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.vendor_attributes`
AS

-- =============================================================================
-- vendor_attributes
-- One row per vendor_number — vendor master data for fraud detection
--
-- SOURCES:
--   gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v
--   gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
--
-- OUTSTANDING DATA ACCESS REQUIRED:
-- [D1] gcp-wow-ent-im-tbl-prod.adp_dm_grouprisk_view.dim_lfbk_vendor_bank_details_v
--      Needed for: bank_country_key, vendor_bank_bsb, vendor_bank_account,
--      bank_account_holder — central to employee-vendor collusion indicator
--      Status: BLOCKED — awaiting access confirmation
--
-- KNOWN LIMITATIONS:
-- [L1] supplier_id (parent entity grouping) is NULL — CorporateGroup in
--      dim_vendor_v is not a meaningful corporate hierarchy field. A dedicated
--      supplier hierarchy table is needed. Raise with Gopi — likely in Ariba
--      supplier master data.
--
-- [L2] local_supplier_flag derived from Country = 'AU' — dim_vendor_v has no
--      explicit local flag. Silver_GNFR_SpendBaseTable_v has a local flag field
--      but it is per-transaction not per-vendor. Country = 'AU' is a reasonable
--      proxy but may not match the risk team's definition exactly.
--
-- [L3] vendor_abn sourced from TaxID field — confirmed as ABN for Australian
--      vendors (11-digit format). TaxNumber1 and TaxNumber2 are unpopulated
--      for Australian vendors. Non-AU vendors will have their local tax ID here.
--
-- [L4] Bank detail fields (bank_country_key, vendor_bank_bsb,
--      vendor_bank_account, bank_account_holder) are NULL pending [D1].
--      These are required for the employee-vendor bank match collusion indicator.
--
-- GRAIN: one row per vendor_number
-- =============================================================================

WITH

-- category from spend base table — dim_vendor_v has no category fields
vendor_category AS (
  SELECT DISTINCT
    vendor_ID,
    Supplier_Custom_Category_L1,
    Supplier_Custom_Category_L2,
    Supplier_Custom_Category_L3
  FROM `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v`
  WHERE
    company_code = '1000'
    AND Supplier_Custom_Category_L1 <> 'Non Addressable'
)

SELECT
  -- primary key
  v.Vendor                                                AS vendor_number,

  -- identity
  v.VendorDescription                                     AS vendor_name,
  v.TaxID                                                 AS vendor_abn,        -- [L3]
  v.VendorStatus                                          AS vendor_status,
  v.DateFirstCreated                                      AS vendor_creation_date,
  v.MarkedforDeletionFlag                                 AS marked_for_deletion,
  v.NonTradeVendorFlag                                    AS non_trade_vendor_flag,

  -- [L1] supplier_id NULL — CorporateGroup is not a meaningful parent entity
  -- field. Dedicated supplier hierarchy table required. Raise with Gopi.
  CAST(NULL AS STRING)                                    AS supplier_id,

  -- address
  v.BuildingNumber                                        AS building_number,
  v.Street                                                AS street,
  v.City                                                  AS city,
  v.PostalCode                                            AS postal_code,
  v.State                                                 AS state,
  v.Country                                               AS country,
  CONCAT(
    COALESCE(v.BuildingNumber, ''), ' ',
    COALESCE(v.Street, ''), ' ',
    COALESCE(v.City, ''), ' ',
    COALESCE(v.PostalCode, ''), ' ',
    COALESCE(v.State, ''), ' ',
    COALESCE(v.Country, '')
  )                                                       AS vendor_full_address,

  -- [L2] local_supplier_flag derived from country
  CASE
    WHEN v.Country = 'AU' THEN 'Y'
    ELSE 'N'
  END                                                     AS local_supplier_flag,

  -- contact
  v.FinancialPartyContactName                             AS financial_party_contact_name,
  v.EmailAddress                                          AS vendor_email,
  v.TelephoneNumber                                       AS vendor_phone,

  -- bank details — [L4] NULL pending dim_lfbk_vendor_bank_details_v access [D1]
  CAST(NULL AS STRING)                                    AS bank_country_key,
  CAST(NULL AS STRING)                                    AS vendor_bank_bsb,
  CAST(NULL AS STRING)                                    AS vendor_bank_account,
  CAST(NULL AS STRING)                                    AS bank_account_holder,

  -- category from spend base table
  vc.Supplier_Custom_Category_L1                          AS supplier_category_l1,
  vc.Supplier_Custom_Category_L2                          AS supplier_category_l2,
  vc.Supplier_Custom_Category_L3                          AS supplier_category_l3

FROM `gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v` v
LEFT JOIN vendor_category vc
  ON v.Vendor = vc.vendor_ID