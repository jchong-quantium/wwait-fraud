CREATE OR REPLACE VIEW fraud.ariba_deleted_user_vw
AS
WITH
  Y AS (
    SELECT DISTINCT
      Approvable_ID,
      Approver,
      row_number() OVER (PARTITION BY Approvable_ID) AS Z
    FROM
      gcp-wow-ent-de-grpproc-prod.gp_ariba.ar_approvals_all_v
    WHERE Approved_by_User = 'Unclassified'
  ),
  X AS (
    SELECT
      *,
      LEAD(Approver)
        OVER (PARTITION BY Approvable_ID ORDER BY assigned_date DESC)
        AS Prev_Approver,
      LEAD(Approver_Reason)
        OVER (PARTITION BY Approvable_ID ORDER BY assigned_date DESC)
        AS Prev_Approver_Reason,
      LEAD(Assigned_Date)
        OVER (PARTITION BY Approvable_ID ORDER BY assigned_date DESC)
        AS Prev_approver_Assigned_Date,
      MAX(Approver)
        OVER (PARTITION BY Approvable_ID ORDER BY assigned_date DESC)
        AS Last_Approver,
    FROM gcp-wow-ent-de-grpproc-prod.gp_ariba.ar_approvals_all_v
    WHERE Approvable_ID IN (SELECT DISTINCT Approvable_ID FROM Y)
  ),
  po_data_line_agg AS (
    SELECT DISTINCT
      PO_Number,
      PO_Date,
      PO_Title,
      PO_Description,
      Supplier_Custom_Category_L2,
      Vendor_Number,
      Vendor_Description,
      Requisition_ID,
      sum(PO_Amount_Invoiced) AS PO_Amount_Invoiced,
      sum(PO_Spend) AS PO_Spend,
      PO_Status,
      --  sum_Paid_Amount_AUD as Amount_Paid,  Tax_Amount ,
      Contract_Id,
      Requestor,
      Approver,
      Cost_Center
    FROM fraud.ariba_po_invoice ar_po
    GROUP BY
      PO_Number, PO_Date, PO_title, PO_Description, Vendor_Number, Contract_Id,
      PO_Status, Requisition_ID, Supplier_Custom_Category_L2, Requestor,
      Approver, Cost_Center, Vendor_Description
  ),
  Z AS (
    SELECT DISTINCT
      po.*,
      cu.Requester_User,
      cu.Approver AS Deleted_User,
      cu.Assigned_Date AS Deleted_User_Date,
      cu.Prev_Approver,
      cu.Prev_approver_Assigned_Date,
      cu.Approver_Deleted_By,
      -- cu.Prev_Approver_Reason,
      --         doa.General_Authority_Limits___Annual_Limit__  as Annual_Limit_Approver_Previous_User, doa.General_Authority___Limits__Multi_Year_Limit__ as Multi_Year_Limit_Approver_Previous_User,
      -- case when PO_Spend > doa.General_Authority_Limits___Annual_Limit__ then 'Yes' else 'No' end as Annual_Limit_Check_Exceeded_Prev_Approver,
      -- case when PO_Spend > doa.General_Authority___Limits__Multi_Year_Limit__ then 'Yes' else 'No' end as MultiYear_Limit_Check_Exceeded_Prev_Approver,
      CASE
        WHEN cu.Approver <> cu.Last_Approver THEN cu.Last_Approver
        END AS Last_Approver
    -- case when cu.Approver <> cu.Last_Approver
    --  and PO_Spend > doa1.General_Authority_Limits___Annual_Limit__ then 'Yes' else 'No' end as Annual_Limit_Check_Exceeded_Last_Approver,
    FROM po_data_line_agg po
    INNER JOIN X cu
      ON
        po.Requisition_ID = cu.Approvable_ID
        AND Approved_by_User = 'Unclassified'
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa
      ON lower(cu.Prev_Approver) = trim(lower(doa.Employee_Name))
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa1
      ON lower(cu.Last_Approver) = trim(lower(doa1.Employee_Name))
  ),
  doa AS (
    SELECT
      Z.*,
      coalesce(Last_Approver, Prev_Approver) AS Final_Approver,
      doa.General_Authority_Limits___Annual_Limit__,
      CASE
        WHEN PO_Spend > doa.General_Authority_Limits___Annual_Limit__ THEN 'Yes'
        ELSE 'No'
        END AS Annual_Limit_Check_Exceeded_Final_Approver
    FROM Z
    LEFT JOIN `gcp-wow-risk-de-data-prod.audit_group_enablement.doa` doa
      ON
        lower(coalesce(Last_Approver, Prev_Approver))
        = trim(lower(doa.Employee_Name))
  )
SELECT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Ariba-Invoices/PO paid outside of approved workflow systems'
    AS routine_description,
  'PO Count' AS metric_description,
  'Count' AS metric_unit,
  f.*,
  'Ariba' AS System,

  -- Time bucket columns as flags
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(f.PO_Date AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM doa f
ORDER BY f.Vendor_Description;
