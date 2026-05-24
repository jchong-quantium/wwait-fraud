CREATE OR REPLACE VIEW fraud.ariba_dupe_po_vw
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
      max(CASE WHEN Z = 7 THEN Approver END) AS Approver_7,
    FROM approvals
    -- where Approvable_ID = 'PR547719'
    GROUP BY Approvable_ID
  ),
  ar_po AS (
    SELECT DISTINCT
      Supplier_Custom_Category_L2,
      ar_po.PO_Number,
      ar_po.Requisition_ID,
      ar_po.PO_Date,
      ar_po.PO_Title AS PO_Description,
      ar_po.Vendor_Number,
      ar_po.Vendor_Description,
      ar_po.PO_Status,
      ar_po.Contract_Id,
      ar_po.Requestor,
      ar_po.Approver,
      ar_po.invoice_id,
      ar_po.PO_Amount_Invoiced AS PO_Amount_Invoiced,
      ar_po.PO_Spend AS PO_Spend,
      sum(ar_po.amount_paid_excl_tax) AS amount_paid_excl_tax
    FROM fraud.ariba_po_invoice ar_po
    WHERE
      vendor_number NOT IN (
        '0096023037', '0098106654', '0096012023', '0053406001', '0071043001',
        '0073499001', '0098102853', '0076017001')
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
  ),
  ariba_po AS (
    SELECT DISTINCT
      ar_po.*,
      fa.Approver_1 AS Approver_1,
      fa.Approver_2 AS Approver_2,
      fa.Approver_3 AS Approver_3,
      Approver_4,
      Approver_5,
      Approver_6,
    FROM ar_po
    LEFT JOIN first_approval fa
      ON fa.Approvable_ID = ar_po.Requisition_ID
  ),
  base_data_1 AS (
    SELECT DISTINCT
      PO_Number,
      PO_Date,
      PO_Description,
      Vendor_Number,
      Vendor_Description,
      PO_Spend,
      PO_Status,
      Supplier_Custom_Category_L2
    FROM ariba_po
    WHERE PO_Spend > 10000
  ),
  base_data AS (
    SELECT DISTINCT
      PO_Number,
      PO_Date,
      PO_Description,
      Vendor_Number,
      Vendor_Description,
      PO_Spend,
      PO_Status,
      Supplier_Custom_Category_L2,
      CONCAT(Vendor_Number, '-', CAST(PO_Spend AS STRING)) AS grouping_key
    FROM base_data_1
  ),
  grouped AS (
    SELECT
      *,
      DENSE_RANK() OVER (ORDER BY grouping_key) AS group_number
    FROM base_data
  ),
  duplicates_only AS (
    SELECT group_number
    FROM grouped
    GROUP BY group_number
    HAVING COUNT(*) > 1
  ),

  -- Get all pairs within 0-3 days in each duplicate group
  valid_pairs AS (
    SELECT
      CONCAT(a.group_number, '-', a.PO_date) AS group_number,
      a.PO_Number AS po1,
      b.PO_Number AS po2,
      DATE_DIFF(a.PO_Date, b.PO_Date, DAY) AS diff
    FROM grouped a
    JOIN grouped b
      ON
        a.group_number = b.group_number
        AND a.PO_Number < b.PO_Number
        AND DATE_DIFF(a.PO_Date, b.PO_Date, DAY) BETWEEN 0 AND 3
  ),

  -- Flatten valid PO Numbers from those pairs
  valid_po_in_range AS (
    SELECT group_number, po1 AS PO_Number FROM valid_pairs
    UNION DISTINCT
    SELECT group_number, po2 AS PO_Number FROM valid_pairs
  ),

  -- Bring in only the POs from valid pairs
  dupe_po AS (
    SELECT
      g.* EXCEPT (group_number),
      v.group_number,
      COUNT(*) OVER (PARTITION BY v.group_number) AS count_group
    FROM grouped g
    JOIN valid_po_in_range v
      ON  # g.group_number = v.group_number AND
        g.PO_Number = v.PO_Number
    QUALIFY count_group > 1
  ),
  po_final AS (
    SELECT
      * EXCEPT (count_group, grouping_key, group_number),
      DENSE_RANK() OVER (ORDER BY group_number) AS group_number
    FROM dupe_po
  )
SELECT DISTINCT
  Supplier_Custom_Category_L2 AS vendor_area,
  'Procurement' AS routine_category,
  'Duplicate POs having same amount, same vendor raised in a span of 0-3 days'
    AS routine_description,
  'Duplicate PO' AS metric_description,
  'Count' AS metric_unit,
  PO_Number,
  PO_Date,
  PO_Description,
  Vendor_Number,
  Vendor_Description,
  PO_Spend,
  PO_Status,
  group_number,
  CONCAT('group ', CAST(group_number AS STRING)) AS dupe_po_group,
  'Ariba' AS system,
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
FROM po_final f
ORDER BY group_number, PO_Number;
