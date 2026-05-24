CREATE OR REPLACE view  `gcp-wow-risk-de-data-prod.fraud.split_invoice_under_threshold_vw`
AS
SELECT *
FROM `gcp-wow-risk-de-data-prod.fraud.sap_split_invoice_under_threshold`
UNION ALL
SELECT *
FROM `gcp-wow-risk-de-data-prod.fraud.ariba_split_invoice_under_threshold`;