CREATE OR REPLACE VIEW fraud.sap_invoices_not_matching_po_vw
AS
WITH
  final_po AS (
    SELECT
      i.*,
      po.* EXCEPT (Supplier_Custom_Category_L2, Vendor_Name, vendor)
    FROM
      fraud.sap_invoices i
    INNER JOIN
      `fraud.sap_po` po
      ON
        po.PurchasingDocumentNumber = i.D_Purchasing_Doc
  ),
  Invoice_Sums AS (
    SELECT
      PurchasingDocumentNumber,
      po_amount_net,
      SUM(Invoice_Amt) AS total_invoice_amt
    FROM final_po
    -- where PurchasingDocumentNumber = '4401155773'
    GROUP BY PurchasingDocumentNumber, po_amount_net
  ),
  invoice_final AS (
    SELECT DISTINCT
      Vendor,
      Vendor_Name,
      Supplier_Custom_Category_L2,
      Invoice_Date,
      Invoice_desc,
      Invoice_Number,
      H_USNAM_User_name,
      D_GL_Account,
      Invoice_Amt,
      total_invoice_amt,
      D_Clearing,
      D_Clrng_doc,
      t.PurchasingDocumentNumber,
      PurchasingDocumentDate,
      DocumentLastChangedOn,
      PurchasingItemShortText,
      t.po_amount_net,
      DocumentCurrency,
      System
    FROM final_po t
    JOIN Invoice_Sums s
      ON t.PurchasingDocumentNumber = s.PurchasingDocumentNumber
    WHERE ABS(s.total_invoice_amt - s.po_amount_net) > 0.01
  )
-- and t.PurchasingDocumentNumber = '4401155773';
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Invoices where sum(invoice) ≠ sum(PO)' AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  PurchasingDocumentNumber AS PO_Order_Id,
  PurchasingDocumentDate AS PO_Date,
  po_amount_net AS sum_PO_Spend_AUD,
  '' AS PO_Status,
  Invoice_Number AS invoice_id,
  Invoice_Date AS invoice_date,
  Invoice_desc AS inv_description,
  '' AS invoice_status,
  Invoice_Amt AS invoice_amt,
  Vendor AS ERP_Supplier_ID,
  Vendor_Name AS ERP_Supplier,
  System AS System,

  -- Time buckets
  CASE
    WHEN
      CAST(Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(Invoice_Date AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM invoice_final
ORDER BY Vendor;
