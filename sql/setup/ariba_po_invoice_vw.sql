CREATE OR REPLACE VIEW ${GCP_PROJECT_ID}.${BQ_DATASET}.ariba_po_invoice_vw
AS
WITH
  vendors AS (
    SELECT DISTINCT vendor_ID, Supplier_Custom_Category_L1, Supplier_Custom_Category_L2, Supplier_Custom_Category_L3
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  po_data_line_agg AS (
    SELECT DISTINCT
      ar_po.PO_Order_Id AS PO_Number,
      ar_po.req_Requisition_ID AS Requisition_ID,
      ar_po.Ordered_Date AS PO_Date,
      Title AS PO_Title,
      ar_po.Supplier_erp_Id AS Vendor_Number,
      ar_po.Supplier_erp_name AS Vendor_Description,
      sum(ar_po.sum_Amount_Invoiced) AS PO_Amount_Invoiced,
      sum(sum_PO_Spend) AS PO_Spend,
      PO_Status,
      ar_po.Contract_Id,
      ar_po.Requester_User AS Requestor,
      ar_po.Requester_Manager_L1 AS Approver,
      ltrim(Cost_Center_Id, '0') AS Cost_Center,
      ar_po.payment_terms AS payment_terms
    FROM
      `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_PO_Linelevel_v`
        ar_po
    WHERE
      CAST(Ordered_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 24 MONTH)
      AND CURRENT_DATE('Australia/Sydney')
    GROUP BY
      ar_po.PO_Order_Id, ar_po.req_Requisition_ID, ar_po.Ordered_Date,
      ar_po.Supplier_erp_Id, ar_po.Supplier_erp_name, ar_po.Contract_Id, Title,
      PO_Status, ar_po.Requester_User, ar_po.Requester_Manager_L1,
      ltrim(Cost_Center_Id, '0'), ar_po.payment_terms
  ),
  invoice_agg AS (
    SELECT DISTINCT
      order_id AS PO_Order_Id,
      Invoice_ID,
      Invoice_date,
      description as inv_description,
      reconciliation_status,
      invoice_status,
      contract_id AS INV_Contract_Id,
      sum(amount_invoiced) AS amount_invoiced,
      (Paid_Amount_AUD) AS Amount_Paid,
      sum(tax_amount_aud) AS tax_paid,
      Paid_Amount_AUD - sum(tax_amount_aud) AS amount_paid_excl_tax
    FROM
      `gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_POandInvoices_v`
    WHERE
      po_ordered_date
      BETWEEN DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 24 MONTH)
      AND CURRENT_DATE('Australia/Sydney')
    GROUP BY
      PO_Order_Id, Invoice_ID, Invoice_date, reconciliation_status,
      invoice_status, contract_id, Paid_Amount_AUD, description
  )
SELECT DISTINCT
  ar_po.*, invoice_agg.*, Supplier_Custom_Category_L1, Supplier_Custom_Category_L2, Supplier_Custom_Category_L3
FROM po_data_line_agg ar_po
JOIN vendors r
  ON ar_po.vendor_number = r.vendor_ID
LEFT JOIN invoice_agg
  ON invoice_agg.PO_Order_Id = ar_po.PO_Number;