CREATE OR REPLACE VIEW fraud.sap_payment_within_1_day_vw
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, supplier_name, Supplier_Custom_Category_L2
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  base_data AS (
    SELECT
      D_Vendor,
      D_Document_Number AS Invoice_Number,
      D_Amount AS Payment_Amount,
      H_Posting_Date AS Payment_Date,
      ROW_NUMBER()
        OVER (PARTITION BY D_Vendor, H_Posting_Date ORDER BY D_Document_Number)
        AS row_num,
      COUNT(*) OVER (PARTITION BY D_Vendor, H_Posting_Date) AS payment_count,
      CASE
        WHEN H_Document_Type = 'Y0' THEN 'Ariba_WDP'
        WHEN H_Document_Type IN ('PX', 'PY', 'VS') THEN 'PEPS'
        WHEN H_Document_Type = 'YM' THEN 'Maximo'
        WHEN
          UPPER(SUBSTR(H_DocHeader_Text, 1, 6)) LIKE '%TMS%'
          OR UPPER(SUBSTR(D_Item_Text, 1, 6)) LIKE '%TMS%'
          THEN 'TMS'
        ELSE 'SAP'
        END AS Purchasing_System
    FROM
      gcp-wow-ent-im-tbl-prod.gs_allgrp_fin_data.bkpf_bseg_accounting_doc_v bseg
    WHERE
      H_Company_Code = '1000'
      AND D_SHKZG_Debit_Credit_Ind = 'H'
      AND (D_Special_GL_ind IS NULL OR D_Special_GL_ind = '')
      AND D_Amount >= 10000
      AND ifnull(D_Vendor, '') <> ''
      AND PARSE_DATE('%Y%m%d', CAST(H_Document_Date AS STRING))
        >= DATE_SUB(CURRENT_DATE(), INTERVAL 24 MONTH)
  ),
  filter_data AS (
    SELECT DISTINCT
      Supplier_Custom_Category_L2 AS vendor_area,
      'Payments' AS routine_category,
      'Scan for multiple payments >$1000 to same vendor within 1 day.'
        AS routine_description,
      'Invoice' AS metric_description,
      'Count' AS metric_unit,
      base_data.Purchasing_System AS System,
      D_Vendor AS Vendor,
      Supplier_Name AS Vendor_Name,
      Invoice_Number,
      Payment_Date,
      Payment_Amount,
      CONCAT(
        'Group ',
        CAST(DENSE_RANK() OVER (ORDER BY D_Vendor, Payment_Date) AS STRING))
        AS Payment_Group,
      CASE
        WHEN
          CAST(Payment_Date AS date)
          BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
          AND CURRENT_DATE()
          THEN 'Y'
        ELSE 'N'
        END AS last_week,
      CASE
        WHEN
          CAST(Payment_Date AS date)
          BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
          AND CURRENT_DATE()
          THEN 'Y'
        ELSE 'N'
        END AS last_month,
      CASE
        WHEN
          CAST(Payment_Date AS date)
          BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
          AND CURRENT_DATE()
          THEN 'Y'
        ELSE 'N'
        END AS last_90_days,
      CASE
        WHEN
          CAST(Payment_Date AS date)
          BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
          AND CURRENT_DATE()
          THEN 'Y'
        ELSE 'N'
        END AS last_180_days,
      CASE
        WHEN
          CAST(Payment_Date AS date)
          BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
          AND CURRENT_DATE()
          THEN 'Y'
        ELSE 'N'
        END AS last_year,
      CASE
        WHEN
          DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
          BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
          AND CURRENT_DATE()
          THEN 'Y'
        ELSE 'N'
        END AS last_last_year
    FROM
      base_data
    INNER JOIN vendors r
      ON D_Vendor = r.vendor_ID
    WHERE
      payment_count > 1
    ORDER BY
      Vendor, Payment_Date, Invoice_Number
  )
SELECT * FROM filter_data;
