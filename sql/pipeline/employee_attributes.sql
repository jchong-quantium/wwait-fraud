-- =============================================================================
-- employee_attributes
-- One row per employee_id — employee master data for fraud detection
--
-- SOURCES:
--   [TODO].Employee.Dim_Employee_Central               — employee identity and employment details
--   gcp-wow-ent-im-people-prod.adp_integrated_people_view.pr_PayrollPaymentInformation_r
--                                                       — employee bank details
--
-- OUTSTANDING DATA ACCESS REQUIRED:
-- [D1] [TODO].Employee.Dim_Employee_Central
--      Needed for: employee_id, first_name, last_name, employee_full_address,
--      employee_bank_key, employment_start_date, employment_status,
--      employee_type, job_title
--      Status: BLOCKED — project path to be confirmed with Gopi (separate
--      Collibra access ticket required)
--
-- [D2] gcp-wow-ent-im-people-prod.adp_integrated_people_view.pr_PayrollPaymentInformation_r
--      Needed for: employee_bank_bsb, employee_bank_account
--      Status: BLOCKED — awaiting access confirmation
--
-- KNOWN LIMITATIONS:
-- [L1] All fields from Dim_Employee_Central are NULL pending [D1].
--      The SELECT below stubs every field from that source with CAST(NULL ...).
--      Replace with real column references once access is granted and the
--      full project path is confirmed.
--
-- [L2] employee_bank_bsb and employee_bank_account are NULL pending [D2].
--      These are the critical fields for the employee-vendor bank match
--      collusion indicator in binary_flags.
--
-- [L3] employee_full_address: to be constructed from address component fields
--      in Dim_Employee_Central once access is confirmed. Column names TBC.
--
-- GRAIN: one row per employee_id
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.employee_attributes`
AS

-- ─────────────────────────────────────────────────────────────────────────────
-- PAYROLL BANK DETAILS
-- Source: gcp-wow-ent-im-people-prod.adp_integrated_people_view.pr_PayrollPaymentInformation_r
-- [D2] BLOCKED — stubbed until access is confirmed
-- ─────────────────────────────────────────────────────────────────────────────

-- TODO: replace this stub with a real query once [D1] and [D2] are resolved.
-- Expected join: Dim_Employee_Central JOIN pr_PayrollPaymentInformation_r
--                ON employee_id = payroll_employee_id (confirm join key with Gopi)

SELECT
  -- primary key
  -- [L1] employee_id NULL — Dim_Employee_Central access pending [D1]
  CAST(NULL AS STRING)                                    AS employee_id,

  -- identity — [L1] all NULL pending Dim_Employee_Central access [D1]
  CAST(NULL AS STRING)                                    AS first_name,
  CAST(NULL AS STRING)                                    AS last_name,

  -- [L3] employee_full_address — constructed from address components in
  -- Dim_Employee_Central once access is confirmed. Column names TBC.
  CAST(NULL AS STRING)                                    AS employee_full_address,

  -- bank details — [L2] NULL pending pr_PayrollPaymentInformation_r access [D2]
  -- CRITICAL: required for employee-vendor bank match collusion indicator
  CAST(NULL AS STRING)                                    AS employee_bank_bsb,
  CAST(NULL AS STRING)                                    AS employee_bank_account,

  -- [L1] employee_bank_key NULL — sourced from Dim_Employee_Central [D1]
  CAST(NULL AS STRING)                                    AS employee_bank_key,

  -- employment details — [L1] all NULL pending Dim_Employee_Central access [D1]
  CAST(NULL AS DATE)                                      AS employment_start_date,
  CAST(NULL AS STRING)                                    AS employment_status,
  CAST(NULL AS STRING)                                    AS employee_type,
  CAST(NULL AS STRING)                                    AS job_title
