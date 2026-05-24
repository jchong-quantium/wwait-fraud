
CREATE OR REPLACE view fraud.invoices_not_matching_po_vw
AS
SELECT * FROM gcp-wow-risk-de-data-prod.fraud.ariba_invoices_not_matching_po
UNION ALL
SELECT * FROM gcp-wow-risk-de-data-prod.fraud.sap_invoices_not_matching_po