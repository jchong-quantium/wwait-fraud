Create or replace view  fraud.ariba_payments_without_approved_po_vw as

With inv as(
   SELECT DISTINCT
      Supplier_Custom_Category_L2 AS vendor_area,
      'Payments' AS routine_category,
      'Payment made without approved PO' AS routine_description,
      'Invoice Count' AS metric_description,
      'Count' AS metric_unit,
      Vendor_Number as ERP_Supplier_ID,
      Invoice_ID,
      Invoice_Date,
      INV_Description,
      Vendor_Description as ERP_Supplier,
      Amount_Paid AS Invoice_Amt_Paid,
      tax_paid AS Tax_Paid,
      amount_paid_excl_tax AS Invoice_Amt_Paid_Excl_Tax,
      Reconciliation_Status,
      PO_Order_Id,
      PO_Spend AS PO_Spend_AUD,
      PO_Status,
    FROM fraud.ariba_po_invoice
    WHERE
      PO_Status <> 'Received'
      AND PO_Order_Id <> 'Unclassified'
      AND Amount_Paid IS NOT NULL
)

SELECT DISTINCT
  f.*,  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Invoice_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM inv f
ORDER BY ERP_Supplier;
