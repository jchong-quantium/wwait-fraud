CREATE OR REPLACE VIEW fraud.sap_multiple_payments_same_vendor_same_amount_vw
AS
WITH
  Potential_Duplicate_Pairs AS (
    -- This CTE identifies pairs of payments that meet the criteria:
    -- 1. Same Vendor (D_Vendor)
    -- 2. Same Payment Amount (Payment_Amount)
    -- 3. Different Payment Clearing Documents (Payment_Clearing_Doc)
    -- 4. Payment_Date_Woolies_A is chronologically before Payment_Date_Woolies_B to avoid duplicate pairs (A,B) and (B,A)
    -- 5. The absolute difference between their Payment_Date_Woolies is 14 days or less.
    SELECT
      a.Payment_Clearing_Doc AS Doc_A,
      b.Payment_Clearing_Doc AS Doc_B
    FROM fraud.base_payment a
    JOIN fraud.base_payment b
      ON
        a.D_Vendor = b.D_Vendor
        AND a.Payment_Amount = b.Payment_Amount
        AND a.Payment_Clearing_Doc
          != b.Payment_Clearing_Doc  -- Ensure 'a' is the earlier payment to avoid duplicate pairs and self-joins
        AND a.Payment_Date_Woolies
          < b.Payment_Date_Woolies  -- Check if the date difference is within 14 days
        AND DATE_DIFF(
          b.Payment_Date_Woolies,
          a.Payment_Date_Woolies,
          DAY)
          <= 30
  ),
  All_Involved_Payments AS (
    -- This CTE collects all unique Payment_Clearing_Doc values from both sides of the identified pairs.
    -- This ensures that every payment that is part of a potential duplicate scenario is included in the final output.
    SELECT Doc_A AS Payment_Clearing_Doc
    FROM Potential_Duplicate_Pairs
    UNION ALL
    SELECT Doc_B AS Payment_Clearing_Doc
    FROM Potential_Duplicate_Pairs
  )
SELECT DISTINCT
  gr.Supplier_Custom_Category_L2 AS vendor_Area,
  'Payments' AS routine_category,
  'SAP - Scan for multiple payments of same amount to same vendor in span of 30 days.'
    AS routine_description,
  'Payment Count' AS metric_description,
  'Count' AS metric_unit,
  bp.D_Vendor AS Vendor,
  supplier_name AS vendor_name,
  CAST(bp.Payment_Date_Woolies AS date) AS Payment_Date_Woolworths,
  CAST(
    bp.Payment_Date_Appears_In_Vendor_Account AS date)
    AS Payment_Date_Appears_In_Vendor_Account,
  bp.Payment_Clearing_Doc,
  bp.Payment_Amount,
  bp.D_GL_Account,
  -- Retained GL Account from original query
  -- Time bucket flags based on Payment_Date_Woolies
  CASE
    WHEN
      CAST(bp.Payment_Date_Woolies AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(bp.Payment_Date_Woolies AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(bp.Payment_Date_Woolies AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(bp.Payment_Date_Woolies AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(bp.Payment_Date_Woolies AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(bp.Payment_Date_Woolies AS DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year
FROM fraud.base_payment bp
JOIN All_Involved_Payments aip
  ON bp.Payment_Clearing_Doc = aip.Payment_Clearing_Doc
JOIN
  (
    SELECT DISTINCT
      vendor_ID AS supplier_ID, supplier_name, Supplier_Custom_Category_L2
    FROM
      gcp-wow-risk-de-lab-dev.gnfr_published_data_sets.Silver_GNFR_SpendBaseTable_v
    WHERE
      company_code = '1000'
      AND Supplier_Custom_Category_L1 <> 'Non Addressable'
  ) gr
  ON bp.D_Vendor = gr.Supplier_ID
ORDER BY bp.D_Vendor, Payment_Date_Woolworths;
