CREATE OR REPLACE view fraud.split_po_under_threshold_vw
AS
SELECT * FROM fraud.sap_split_po_under_threshold
UNION ALL
SELECT * FROM fraud.ariba_split_po_under_threshold;