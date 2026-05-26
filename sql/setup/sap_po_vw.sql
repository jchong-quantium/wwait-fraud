CREATE OR REPLACE VIEW gcp-wow-groupit-bizwear-dev.fraud.sap_po_vw
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L2, supplier_name
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  document_line AS (
    SELECT DISTINCT
      PurchasingDocumentNumber,
      PurchasingDocumentItem,
      Vendor,
      PurchasingDocumentDate,
      DocumentLastChangedOn,
      PurchasingItemShortText,
      GrossOrderValue,
      NetOrderValue,
      DocumentCurrency
    FROM
      `gcp-wow-ent-im-tbl-prod.adp_dm_purchasing_view.document_schedule_lines_v`
    WHERE
      PurchasingDocumentDate >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
      AND PurchasingOrganization = '1000'
  ),
  po_unagg AS (
    SELECT
      PurchasingDocumentNumber,
      PurchasingDocumentItem,
      vendor_ID AS Vendor,
      Supplier_Name AS Vendor_Name,
      Supplier_Custom_Category_L2,
      PurchasingDocumentDate,
      DocumentLastChangedOn,
      PurchasingItemShortText,
      GrossOrderValue,
      NetOrderValue,
      DocumentCurrency
    FROM document_line sl
    INNER JOIN
      vendors gr
      ON
        ltrim(gr.vendor_ID, '0')
        = ltrim(sl.vendor, '0')

    -- and PurchasingDocumentNumber = '4401155773'
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2,
  PurchasingDocumentNumber,
  Vendor,
  Vendor_Name,
  PurchasingDocumentDate,
  max(DocumentLastChangedOn) AS DocumentLastChangedOn,
  max(PurchasingItemShortText) AS PurchasingItemShortText,
  DocumentCurrency,
  sum(GrossOrderValue) AS po_amount_gross,
  sum(NetOrderValue) AS po_amount_net
FROM po_unagg
GROUP BY
  Supplier_Custom_Category_L2, PurchasingDocumentNumber, Vendor, Vendor_Name,
  PurchasingDocumentDate, DocumentCurrency;