CREATE OR REPLACE PROCEDURE `project-5c016d48-80d5-4534-b69.orc_dataset.sp_log_etl_run`(
  p_run_id         INT64,
  p_procedure_name STRING,
  p_step_name      STRING,
  p_status         STRING,
  p_rows_affected  INT64,
  p_message        STRING,
  p_error_code     INT64
)
BEGIN
  -- NOTE: PRAGMA AUTONOMOUS_TRANSACTION and COMMIT removed. Outside an explicit transaction each statement
  --       commits on its own, so callers must invoke this outside BEGIN/COMMIT TRANSACTION for the row to survive a rollback.
  -- NOTE: Oracle DEFAULT NULL parameters are not supported; callers pass NULL explicitly.
  INSERT INTO `project-5c016d48-80d5-4534-b69.orc_dataset.etl_run_log`
    (run_id, procedure_name, step_name, status, rows_affected, message, error_code, log_ts)
  VALUES (
    p_run_id,
    UPPER(p_procedure_name),
    UPPER(p_step_name),
    UPPER(p_status),
    p_rows_affected,
    SUBSTR(p_message, 1, 4000),
    p_error_code,
    CURRENT_TIMESTAMP()
  );
EXCEPTION WHEN ERROR THEN
  -- NOTE: DBMS_OUTPUT.PUT_LINE replaced by SELECT; logging failures are swallowed as in Oracle.
  SELECT CONCAT('SP_LOG_ETL_RUN failed for ', IFNULL(p_procedure_name, ''), '/', IFNULL(p_step_name, ''), ': ', @@error.message) AS log_error;
END;
