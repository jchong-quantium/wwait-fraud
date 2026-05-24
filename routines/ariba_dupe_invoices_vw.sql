CREATE OR REPLACE VIEW fraud.ariba_dupe_invoices_vw
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
  --  Load and filter relevant invoices
  inv AS (
    SELECT DISTINCT
      -- Supplier_Custom_Category_L2
      order_id AS PO_Order_Id,
      po_ordered_date AS PO_Date,
      po_status,
      Invoice_ID,
      Invoice_date,
      description AS inv_description,
      invoice_status,
      contract_id AS INV_Contract_Id,
      -- supplier_erp_supplier AS ERP_Supplier,
      -- ERP_Supplier_ID
      sum(amount_invoiced) AS amount_invoiced,
      (Paid_Amount_AUD) AS Amount_Paid,
      sum(tax_amount_aud) AS tax_paid,
      Paid_Amount_AUD - sum(tax_amount_aud) AS amount_paid_excl_tax
    FROM
      `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_POandInvoices_v`
    WHERE
      Invoice_date
      BETWEEN DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 24 MONTH)
      AND CURRENT_DATE('Australia/Sydney')
    GROUP BY
      PO_Order_Id, po_ordered_date, po_status, Invoice_ID, Invoice_date,
      invoice_status, contract_id, Paid_Amount_AUD, description
  ),
  Vend_po AS (
    SELECT DISTINCT
      a.Vendor_ID AS ERP_Supplier_ID,
      Supplier_Name AS ERP_Supplier,
      PO_document AS PO_Order_Id,
      a.Supplier_Custom_Category_L2
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        a
    JOIN vendors v
      ON a.Vendor_ID = v.vendor_ID
    JOIN inv
      ON inv.PO_Order_Id = a.PO_document
  ),
  x AS (
    SELECT DISTINCT
      Supplier_Custom_Category_L2,
      inv.PO_Order_Id,
      PO_Date,
      po_status,
      Invoice_ID,
      Invoice_date,
      inv_description,
      invoice_status,
      INV_Contract_Id,
      ERP_Supplier,
      ERP_Supplier_ID,
      amount_invoiced,
      Amount_Paid,
      tax_paid,
      amount_paid_excl_tax
    FROM inv
    JOIN Vend_po
      ON vend_po.PO_Order_Id = inv.PO_Order_Id
    WHERE
      amount_paid_excl_tax <> 0
      AND inv.PO_Order_Id <> 'Unclassified'
  ),
  part_2 AS (
    SELECT
      *,
      COUNT(*)
        OVER (
          PARTITION BY
            Invoice_Date, ERP_Supplier_ID, CAST(amount_paid_excl_tax AS string)
        ) AS Z
    FROM X
  ),
  part_3 AS (
    SELECT * FROM part_2 WHERE Z > 1
  ),
  part_4 AS (
    SELECT
      *,
      dense_rank()
        OVER (ORDER BY Invoice_Date, ERP_Supplier_ID, amount_paid_excl_tax)
        AS rnk
    FROM part_3
  )
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Scan duplicate invoices having same amount, same vendor (even if PO numbers are different) raised on same day'
    AS routine_description,
  'Duplicate Invoice' AS metric_description,
  'Count' AS metric_unit,
  Invoice_ID,
  Invoice_Date,
  Inv_Description,
  amount_paid_excl_tax AS invoice_amt_paid,
  ERP_Supplier_ID,
  ERP_Supplier,
  '' AS H_USNAM_User_name,
  '' AS D_GL_Account,
  '' AS D_Clearing,
  '' AS D_Clrng_doc,
  'Ariba' AS System,
  rnk AS group_number,
  CONCAT('Group ', CAST(rnk AS STRING)) AS dupe_invoice_group,

  -- Time flags
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      Invoice_Date
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM part_4
ORDER BY rnk, Invoice_Date;
