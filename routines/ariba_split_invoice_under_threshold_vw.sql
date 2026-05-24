CREATE OR REPLACE VIEW `fraud.ariba_split_invoice_under_threshold_vw`
AS
WITH
  vendors AS (
    SELECT DISTINCT
      vendor_ID,
      Supplier_Name,
      Supplier_Custom_Category_L2,
      PO_document AS PO_Order_Id,
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
        r
    JOIN
      (
        SELECT DISTINCT fiscalyear
        FROM gcp-wow-ent-im-tbl-prod.adp_dm_masterdata_view.dim_date_v d
        WHERE
          CalendarDay
          BETWEEN DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 24 MONTH)
          AND CURRENT_DATE('Australia/Sydney')
      ) d
      ON d.fiscalyear = CAST(r.fiscal_year AS int64)
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ),
  invoice AS (
    SELECT DISTINCT
      order_id AS PO_Order_Id,
      sum(amount_invoiced) AS amount_invoiced,
      (Paid_Amount_AUD) AS sum_Paid_Amount_AUD,
      sum(tax_amount_aud) AS tax_paid,
      Paid_Amount_AUD - sum(tax_amount_aud) AS amount_paid_excl_tax,
      Invoice_Date,
      Invoice_ID,
      max(description) AS inv_description,
      Reconciliation_Status,
      max(PO_Status) AS PO_status
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_Ariba_POandInvoices_v
        ar_po
    WHERE
      Invoice_date
        BETWEEN DATE_SUB(CURRENT_DATE('Australia/Sydney'), INTERVAL 24 MONTH)
        AND CURRENT_DATE('Australia/Sydney')
      AND Paid_Amount_AUD <> 0
    -- and PO_Order_Id = '3700602225'
    GROUP BY
      PO_Order_Id, Invoice_Date, Invoice_ID, Reconciliation_Status,
      Paid_Amount_AUD
  ),
  invoice_agg AS (
    SELECT
      invoice.*,
      vendor_ID AS ERP_Supplier,
      supplier_Custom_Category_L2,
      Supplier_Name,
    FROM invoice
    JOIN vendors v
      ON invoice.PO_Order_Id = v.PO_Order_Id
  ),
  -- Only keep invoices under $50K excl. tax
  filtered_invoices AS (
    SELECT *
    FROM invoice_agg
    WHERE amount_paid_excl_tax < 50000
  ),

  -- Group invoices from same vendor and same invoice date
  grouped_invoices AS (
    SELECT
      ERP_Supplier AS Vendor_Number,
      Supplier_Name AS Vendor_Description,
      Invoice_Date,
      COUNT(DISTINCT Invoice_ID) AS invoice_count,
      SUM(amount_paid_excl_tax) AS total_group_amount
    FROM filtered_invoices
    GROUP BY Vendor_Number, Invoice_Date, Vendor_Description
    HAVING
      COUNT(DISTINCT Invoice_ID) > 1
      AND SUM(amount_paid_excl_tax) >= 50000
  ),

  -- Add group IDs and bring back invoice-level detail
  flagged_invoices AS (
    SELECT
      f.*,
      g.total_group_amount,
      DENSE_RANK() OVER (ORDER BY g.Vendor_Number, g.Invoice_Date) AS group_id,
      CONCAT(
        'Group ', DENSE_RANK() OVER (ORDER BY g.Vendor_Number, g.Invoice_Date))
        AS split_invoice_group
    FROM filtered_invoices f
    INNER JOIN grouped_invoices g
      ON
        f.ERP_Supplier = g.Vendor_Number
        AND f.Invoice_Date = g.Invoice_Date
  )
SELECT DISTINCT
  supplier_Custom_Category_L2 AS vendor_area,
  'Payments' AS routine_category,
  'Detect potential invoice splitting by identifying multiple invoices from the same vendor on the same day where the combined total exceeds the threshold of $50,000.'
    AS routine_description,
  'Invoice Count' AS metric_description,
  'Count' AS metric_unit,
  ERP_Supplier AS Vendor,
  Supplier_Name AS Vendor_Description,
  Invoice_Date,
  total_group_amount AS Total_Group_Invoice_Amount,
  Invoice_ID,
  amount_paid_excl_tax AS Invoice_Amount_Ex_Tax,
  group_id AS Group_ID,
  split_invoice_group AS SplitInvoice_Group,
  INV_Description,
  Reconciliation_Status,
  'Ariba' AS System,

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
FROM flagged_invoices
-- where ERP_Supplier='0096031876'
ORDER BY group_id ASC;
