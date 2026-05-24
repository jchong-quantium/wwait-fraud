CREATE OR REPLACE VIEW gcp-wow-risk-de-data-prod.fraud.invoice_approved_closed_to_doa_vw
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
  approvals_last AS (
    SELECT DISTINCT
      Approvable_ID,
      real_user AS Approver,
      row_number()
        OVER (PARTITION BY Approvable_ID ORDER BY Action_Date DESC) AS L
    FROM
      gcp-wow-ent-de-grpproc-prod.gp_ariba.ar_approvals_all_v
  ),
  approvals_last_filter AS (
    SELECT * FROM approvals_last WHERE L = 1
  ),
  req_po AS (
    SELECT DISTINCT req_requisition_id, po_order_id AS REQ_Order_Id
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_PO_Linelevel_v
  ),
  X AS (
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
      po_data_line_agg.Approver,
      Cost_Center,
      Invoice_ID,
      Invoice_date,
      Inv_description,
      amount_paid AS sum_Paid_Amount_AUD,
      tax_paid,
      amount_paid_excl_tax,
      REQ_Requisition_ID,
      fa.Approver_1 AS Approver_1,
      doa.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_1,
      -- doa.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_1,
      fa.Approver_2 AS Approver_2,
      doa2.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_2,
      -- doa2.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_2,
      fa.Approver_3 AS Approver_3,
      doa3.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_3,
      -- doa3.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_3,
      Approver_4,
      doa4.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_4,
      -- doa4.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_4,
      Approver_5,
      doa5.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_5,
      -- doa5.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_5,
      Approver_6,
      doa6.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_6,
      -- doa6.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_6,
      Approver_7,
      doa7.General_Authority_Limits___Annual_Limit__ AS Annual_Limit_Approver_7,
      -- doa7.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_7,
      la.Approver AS Last_Approver,
      doa8.General_Authority_Limits___Annual_Limit__
        AS Annual_Limit_Approver_Last
    -- doa8.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_Last
    FROM fraud.ariba_po_invoice po_data_line_agg
    LEFT JOIN req_po
      ON po_data_line_agg.PO_Number = req_po.REQ_Order_Id
    LEFT JOIN first_approval fa
      ON fa.Approvable_ID = req_po.REQ_Requisition_ID
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa
      ON lower(fa.Approver_1) = trim(lower(doa.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa2
      ON lower(fa.Approver_2) = trim(lower(doa2.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa3
      ON lower(fa.Approver_3) = trim(lower(doa3.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa4
      ON lower(fa.Approver_4) = trim(lower(doa4.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa5
      ON lower(fa.Approver_5) = trim(lower(doa5.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa6
      ON lower(fa.Approver_6) = trim(lower(doa6.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa7
      ON lower(fa.Approver_7) = trim(lower(doa7.Employee_Name))
    LEFT JOIN approvals_last_filter la
      ON la.Approvable_ID = req_po.REQ_Requisition_ID
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa8
      ON lower(la.Approver) = trim(lower(doa8.Employee_Name))
  ),
  Y AS (
    SELECT
      *,
      CASE
        WHEN PO_Spend > Annual_Limit_Approver_Last THEN 'Yes'
        ELSE 'No'
        END AS Annual_Limit_Check_Last_Approver,
    -- case when PO_Spend > Multi_Year_Limit_Approver_Last then 'Yes' else 'No' end as Multi_Year_Limit_Check_Last_Approver
    FROM X
  ),
  f AS (
    SELECT
      *
        EXCEPT (
          Contract_Id, Approver, Cost_center, tax_paid, sum_Paid_Amount_AUD)
    FROM Y
    WHERE PO_Number <> 'Unclassified'
  ),
  m AS (
    SELECT DISTINCT
      Supplier_Custom_Category_L2,
      PO_Number,
      --   PO_Date,
      --   PO_Description,
      Invoice_id,
      Invoice_date,
      Inv_description,
      amount_paid_excl_tax AS Invoice_Amount,
      Vendor_Number,
      Vendor_Description,
      PO_Status,
      Requestor,
      REQ_Requisition_ID,
      --   Approver_1,
      --   Annual_Limit_Approver_1,
      --   Approver_2,
      --   Annual_Limit_Approver_2,
      --   Approver_3,
      --   Annual_Limit_Approver_3,
      --   Approver_4,
      --   Annual_Limit_Approver_4,
      --   Approver_5,
      --   Annual_Limit_Approver_5,
      --   Approver_6,
      --   Annual_Limit_Approver_6,
      --   Approver_7,
      --   Annual_Limit_Approver_7,
      Last_Approver,
      Annual_Limit_Approver_Last,
      CASE
        WHEN
          ABS(amount_paid_excl_tax - Annual_Limit_Approver_Last)
          <= (0.10 * Annual_Limit_Approver_Last)
          THEN 'Close to Limit'
        ELSE 'Not Close'
        END AS po_spend_proximity_flag
    FROM f
  ),
  n AS (
    SELECT * FROM m WHERE po_spend_proximity_flag = 'Close to Limit'
  )

-- 3700860772
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Ariba - Employees frequently approving invoices/PO close to their DOA limit'
    AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  *,
  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.Invoice_date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.Invoice_date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.Invoice_date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.Invoice_date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.Invoice_date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.Invoice_date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM n f
ORDER BY Vendor_Number;
