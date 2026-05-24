CREATE OR REPLACE TABLE fraud.duplicate_po_vw
AS
WITH
  all_po
  AS (
    SELECT * FROM gcp-wow-risk-de-data-prod.fraud.ariba_duplicate_po
    UNION ALL
    SELECT * FROM gcp-wow-risk-de-data-prod.fraud.sap_duplicate_po
    UNION ALL
    SELECT * FROM gcp-wow-risk-de-data-prod.fraud.maximo_duplicate_po
  ),
  duplicate_po_n1
  AS (
    SELECT *
    FROM all_po
    WHERE dupe_po_group IS NOT NULL AND group_number IS NOT NULL
    ORDER BY group_number
  )
SELECT *
FROM duplicate_po_n1
ORDER BY system, Vendor_Number, group_number ASC;