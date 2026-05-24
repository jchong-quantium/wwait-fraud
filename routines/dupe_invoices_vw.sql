CREATE OR REPLACE view gcp-wow-risk-de-data-prod.fraud.dupe_invoices_vw
AS
SELECT * FROM gcp-wow-risk-de-data-prod.fraud.ariba_dupe_invoices
UNION ALL
SELECT * FROM gcp-wow-risk-de-data-prod.fraud.sap_dupe_invoices;