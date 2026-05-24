CREATE OR REPLACE VIEW fraud.ariba_approvals_data_vw
AS
WITH
  approvals AS (
    SELECT DISTINCT
      Approvable_ID,
      real_user AS Approver,
      row_number()
        OVER (PARTITION BY Approvable_ID ORDER BY Action_Date ASC) AS Z
    FROM
      gcp-wow-ent-de-grpproc-prod.gp_ariba.ar_approvals_all_v
  ),
  first_approval AS (
    SELECT
      Approvable_ID,
      max(CASE WHEN Z = 1 THEN Approver END) AS Approver_1,
      max(CASE WHEN Z = 2 THEN Approver END) AS Approver_2,
      max(CASE WHEN Z = 3 THEN Approver END) AS Approver_3,
      max(CASE WHEN Z = 4 THEN Approver END) AS Approver_4,
      max(CASE WHEN Z = 5 THEN Approver END) AS Approver_5,
      max(CASE WHEN Z = 6 THEN Approver END) AS Approver_6,
      max(CASE WHEN Z = 7 THEN Approver END) AS Approver_7
    FROM approvals
    -- where Approvable_ID = 'PR547719'
    GROUP BY Approvable_ID
  ),
  req_po AS (
    SELECT DISTINCT req_requisition_id, po_order_id as REQ_Order_Id
    FROM gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_PO_Linelevel_v
  )
SELECT DISTINCT 
      PO_Number,
      PO_Date,
      PO_Title,
      PO_Description,
      Vendor_Number,
      Vendor_Description,
      Supplier_Custom_Category_L2,
      PO_Amount_Invoiced,
      PO_Spend,
      PO_Status,
      Contract_Id,
      Requestor,
      Approver,
      Cost_Center, fa.*
FROM gcp-wow-risk-de-data-prod.fraud.ariba_po_invoice po_data_line_agg
LEFT JOIN req_po
  ON po_data_line_agg.PO_Number = req_po.REQ_Order_Id
LEFT JOIN first_approval fa
  ON fa.Approvable_ID = req_po.REQ_Requisition_ID