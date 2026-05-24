CREATE OR REPLACE VIEW `fraud.base_payment_vw`
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, supplier_name, Supplier_Custom_Category_L2
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  Payments_vendor AS (
    SELECT DISTINCT
      COALESCE(bseg.D_Vendor, vendor_ID) D_Vendor,
      gr.Supplier_Name AS Vendor_Name,
      Supplier_Custom_Category_L2,
      CAST(
        FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.H_Document_Date))
        AS date) AS Payment_Date_Woolies,
      bseg.D_GL_Account,
      CASE
        WHEN D_SHKZG_Debit_Credit_Ind = 'H' THEN -D_Amount_in_LC
        ELSE D_Amount_in_LC
        END
        AS Amount_In_LC,
      FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.D_Clearing))
        AS D_Clearing,
      D_Clrng_doc
    FROM
      gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v bseg
    INNER JOIN vendors gr
      ON gr.vendor_ID = bseg.D_vendor
    WHERE
      H_Document_Type IN ('ZP')
      AND H_Company_Code = '1000'
      AND PARSE_DATE('%Y%m%d', CAST(H_Document_Date AS STRING))
        >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
  ),
  payment_doc AS (
    SELECT DISTINCT
      COALESCE(bseg.D_Vendor, vendor_ID) D_Vendor,
      gr.Supplier_Name AS Vendor_Name,
      Supplier_Custom_Category_L2,
      safe_cast(
        FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.H_Document_Date))
        AS date) AS Payment_Date_Woolies,
      bseg.D_GL_Account,
      CASE
        WHEN D_SHKZG_Debit_Credit_Ind = 'H' THEN -D_Amount_in_LC
        ELSE D_Amount_in_LC
        END
        AS Amount_In_LC,
      FORMAT_DATE('%Y-%m-%d', PARSE_DATE('%Y%m%d', bseg.D_Clearing))
        AS D_Clearing,
      D_Clrng_doc
    FROM
      gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v bseg
    JOIN
      (
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
      ) gr
      ON
        bseg.H_Document_Number = gr.Invoice_document
        AND bseg.D_BUZEI_Line_item = Invoice_Line_Item
    WHERE
      bseg.D_Clearing <> '00000000'
      AND H_Document_Type IN ('ZP')
      AND H_Company_Code = '1000'
      AND H_Posting_Date > DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
  ),
  Payments_A AS (
    SELECT * FROM Payments_vendor
    UNION DISTINCT
    SELECT * FROM payment_doc
  ),
  Payments_B AS (
    SELECT DISTINCT
      D_Vendor,
      Vendor_Name,
      Supplier_Custom_Category_L2,
      Payment_Date_Woolies,
      D_GL_Account,
      D_Clearing AS Payment_Date_Appears_In_Vendor_Account,
      D_Clrng_doc AS Payment_Clearing_Doc,
      sum(Amount_In_LC) AS Payment_Amount
    FROM Payments_A
    GROUP BY 1, 2, 3, 4, 5, 6, 7
  )
SELECT * FROM Payments_B WHERE D_vendor <> ''
