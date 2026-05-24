CREATE OR REPLACE VIEW `fraud.maximo_po_vw`
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
  x AS (
    SELECT DISTINCT
      Supplier_Custom_Category_L2,
      P.PONUM,
      P.DESCRIPTION,
      P.ORDERDATE,
      P.POTYPE,
      P.REVISIONNUM,
      P.STATUS,
      P.STATUSDATE,
      P.HISTORYFLAG,
      P.VENDOR,
      V.NAME AS VENDOR_NAME,
      P.CONTRACTREFID,
      P.CHANGEDATE,
      P.CHANGEBY,
      X.DISPLAYNAME AS CHANGED_BY_NAME,
      P.REVCOMMENTS,
      P.TOTALCOST,
      P.TOTALTAX1,
      row_number() OVER (PARTITION BY PONUM ORDER BY P.CHANGEDATE DESC) AS z
    FROM gcp-wow-fac-de-data-prod.maximo.PO P
    JOIN gcp-wow-fac-de-data-prod.maximo.PERSON X
      ON X.PERSONID = P.CHANGEBY AND X.ISDELETED IS NULL
    JOIN gcp-wow-fac-de-data-prod.maximo.COMPANIES V
      ON V.COMPANY = P.VENDOR AND V.ISDELETED IS NULL
    JOIN vendors gr
      ON ltrim(gr.vendor_ID, '0') = ltrim(P.vendor, '0')
    WHERE
      -- AND     PONUM = 'PB100020
      P.ORDERDATE >= DATE_ADD(
        CURRENT_DATE('Australia/Sydney'), INTERVAL -24 MONTH)
      AND P.ISDELETED IS NULL
      -- Ensures we only get the latest copy of the PERSON record
      AND X.GCP_VALID_UNTIL IS NULL
    ORDER BY P.PONUM, P.STATUSDATE
  ),
  po_unagg AS (
    SELECT *
    FROM x
    WHERE z = 1
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2,
  PONUM AS PurchasingDocumentNumber,
  Vendor,
  Vendor_Name,
  ORDERDATE AS PurchasingDocumentDate,
  CHANGEDATE AS DocumentLastChangedOn,
  DESCRIPTION AS PurchasingItemShortText,
  NULL AS DocumentCurrency,
  TOTALCOST AS po_amount_net,
  STATUS,
  TOTALCOST AS po_amount_gross
FROM po_unagg;
