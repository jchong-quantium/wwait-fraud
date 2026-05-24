CREATE OR REPLACE VIEW fraud.payments_employee_vendor_sharing_bankdetails_vw
AS
SELECT
  a.*
    EXCEPT (
      routine_description,
      metric_description,
      last_week,
      last_month,
      last_90_days,
      last_180_days,
      last_year,
      last_last_year),
  CAST(Payment_Date_Woolies AS date) Payment_Date_Woolies,
  Payment_Amount,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_week,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_month,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_90_days,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_180_days,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      AND CURRENT_DATE()
      THEN 'Y'
    ELSE 'N'
    END AS last_year,
  CASE
    WHEN
      CAST(Payment_Date_Woolies AS date)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 2 YEAR)
      AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 YEAR)
      THEN 'Y'
    ELSE 'N'
    END AS last_last_year,
  'Scan for same bank details between vendors and employees with payments over 5000'
    routine_description,
  'Employee Count' metric_description
FROM fraud.vendors_employee_with_same_bankdetails a
JOIN fraud.base_payment b
  ON a.supplier_id = b.D_Vendor
WHERE payment_amount > 5000
