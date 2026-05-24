CREATE OR REPLACE VIEW fraud.vendor_profile_vw
AS
WITH
  pt AS (
    SELECT DISTINCT
      Payment_Terms AS payment_terms,
      Payment_Terms_Desc AS payment_terms_description,
    FROM gcp-wow-ent-im-tbl-prod.gs_smkt_fin_data.fin_vwc_analysis_v fin
  )
SELECT
  vendor_id AS supplier_id,
  Supplier_Name,
  CountryDescription AS country,
  CASE
    WHEN supplier_Country = 'AU' THEN 'Y'
    ELSE 'N'
    END AS local_supplier_flag,
  Supplier_Custom_Category_L1,
  Supplier_Custom_Category_L2,
  Supplier_Custom_Category_L3,
  a.Payment_Terms,
  -- SPLIT(Ariba_payment_terms, '-')[SAFE_OFFSET(1)] AS Payment_Terms_Description,
  payment_terms_description,
  Purchasing_System,
  fiscal_year,
  company_code,
  sum(amount) AS supplier_spend,
FROM
  gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
    a
LEFT JOIN gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_vendor_v vend
  ON a.vendor_id = vend.Vendor
LEFT JOIN pt
  ON pt.payment_terms = a.payment_terms
WHERE
  Company_Code = '1000'
  AND Supplier_Custom_Category_L1 <> 'Non Addressable'
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
