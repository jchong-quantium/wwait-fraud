CREATE OR REPLACE VIEW gcp-wow-groupit-bizwear-dev.fraud.sap_invoices_vw
AS
WITH
  vendor AS (
    SELECT DISTINCT
      vendor_ID,
      supplier_name,
      Supplier_Custom_Category_L2,
      Invoice_document,
      Invoice_Line_Item
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  invoice_po AS (
    SELECT DISTINCT
      COALESCE(bseg.D_Vendor, gr.vendor_ID) AS vendor,
      Supplier_Name AS Vendor_Name,
      Supplier_Custom_Category_L2,
      CAST(
        FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.H_Document_Date))
        AS date) AS Invoice_Date,
      H_DocHeader_Text AS Invoice_desc,
      H_Reference AS Invoice_Number,
      H_USNAM_User_name,
      bseg.D_GL_Account,
      D_Amount_in_LC AS Invoice_Amt,
      D_Clearing,
      D_Clrng_doc,
      bseg.D_Purchasing_Doc,  -- Added PO field
      CASE
        WHEN H_Document_Type = 'Y0' THEN 'Ariba'
        WHEN H_Document_Type = 'VN' AND H_DocHeader_Text LIKE '%TPUE%'
          THEN 'SAP'
        WHEN
          H_Document_Type IN ('RN')
          AND lower(H_DocHeader_Text) LIKE '%ariba_asn%'
          THEN 'ARIBA_ASN'
        WHEN H_Document_Type IN ('RN') AND lower(H_DocHeader_Text) LIKE '%cptp%'
          THEN 'Manually Keyed Capital Invoice'
        WHEN H_Document_Type IN ('YM') THEN 'Maximo'
        WHEN H_Document_Type IN ('VS') THEN 'PEPs Property Leases'
        WHEN H_Document_Type IN ('VN') AND H_USNAM_User_name LIKE '%RBTGM0007%'
          THEN 'Smartsheet Robot'
        WHEN
          H_Document_Type IN ('VN')
          AND lower(H_USNAM_User_name) LIKE '%wf_batch%'
          THEN 'VIM Docs'
        WHEN H_Document_Type IN ('FI', 'FN', 'FR', 'ZF') THEN 'Overseas'
        END AS System
    FROM
      gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v bseg
    JOIN vendor gr
      ON
        bseg.H_Document_Number = gr.Invoice_document
        AND bseg.D_BUZEI_Line_item = Invoice_Line_Item
    WHERE
      H_Company_Code = '1000'
      AND H_Document_Type IN (
        'Y0', 'VN', 'RN', 'YM', 'VS', 'FI', 'FN', 'FR', 'ZF')
      AND PARSE_DATE('%Y%m%d', CAST(H_Document_Date AS STRING))
        >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
  ),
  invoice_po_vendor AS (
    SELECT DISTINCT
      COALESCE(bseg.D_Vendor) AS vendor,
      Supplier_Name AS Vendor_Name,
      Supplier_Custom_Category_L2,
      CAST(
        FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.H_Document_Date))
        AS date) AS Invoice_Date,
      H_DocHeader_Text AS Invoice_desc,
      H_Reference AS Invoice_Number,
      H_USNAM_User_name,
      bseg.D_GL_Account,
      D_Amount_in_LC AS Invoice_Amt,
      D_Clearing,
      D_Clrng_doc,
      bseg.D_Purchasing_Doc,  -- Added PO field
      CASE
        WHEN H_Document_Type = 'Y0' THEN 'Ariba'
        WHEN H_Document_Type = 'VN' AND H_DocHeader_Text LIKE '%TPUE%'
          THEN 'SAP'
        WHEN
          H_Document_Type IN ('RN')
          AND lower(H_DocHeader_Text) LIKE '%ariba_asn%'
          THEN 'ARIBA_ASN'
        WHEN H_Document_Type IN ('RN') AND lower(H_DocHeader_Text) LIKE '%cptp%'
          THEN 'Manually Keyed Capital Invoice'
        WHEN H_Document_Type IN ('YM') THEN 'Maximo'
        WHEN H_Document_Type IN ('VS') THEN 'PEPs Property Leases'
        WHEN H_Document_Type IN ('VN') AND H_USNAM_User_name LIKE '%RBTGM0007%'
          THEN 'Smartsheet Robot'
        WHEN
          H_Document_Type IN ('VN')
          AND lower(H_USNAM_User_name) LIKE '%wf_batch%'
          THEN 'VIM Docs'
        WHEN H_Document_Type IN ('FI', 'FN', 'FR', 'ZF') THEN 'Overseas'
        END AS System
    FROM
      gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v bseg
    JOIN
      (
        SELECT DISTINCT vendor_ID, Supplier_Name, Supplier_Custom_Category_L2
        FROM vendor
      ) gr
      ON
        bseg.D_Vendor = gr.vendor_ID
    WHERE
      H_Document_Type IN ('Y0', 'VN', 'RN', 'YM', 'VS', 'FI', 'FN', 'FR', 'ZF')
      AND H_Company_Code = '1000'
      AND PARSE_DATE('%Y%m%d', CAST(H_Document_Date AS STRING))
        >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
  )
SELECT * FROM invoice_po_vendor WHERE system <> ''
UNION DISTINCT
SELECT * FROM invoice_po WHERE system <> '';