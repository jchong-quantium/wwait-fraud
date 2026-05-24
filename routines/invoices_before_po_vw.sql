
CREATE OR REPLACE view fraud.invoices_before_po_vw
AS
SELECT * FROM fraud.ariba_invoices_before_po
UNION ALL
SELECT * FROM fraud.sap_invoices_before_po;