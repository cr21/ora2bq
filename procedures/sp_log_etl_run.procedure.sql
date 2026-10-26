CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_LOG_ETL_RUN" (
    p_run_id          IN etl_run_log.run_id%TYPE,
    p_procedure_name  IN etl_run_log.procedure_name%TYPE,
    p_step_name       IN etl_run_log.step_name%TYPE,
    p_status          IN etl_run_log.status%TYPE,
    p_rows_affected   IN etl_run_log.rows_affected%TYPE DEFAULT NULL,
    p_message         IN VARCHAR2                       DEFAULT NULL,
    p_error_code      IN etl_run_log.error_code%TYPE    DEFAULT NULL
)
AS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO etl_run_log (run_id, procedure_name, step_name, status, rows_affected, message, error_code, log_ts)
    VALUES (p_run_id,
            UPPER(p_procedure_name),
            UPPER(p_step_name),
            UPPER(p_status),
            p_rows_affected,
            SUBSTR(p_message, 1, 4000),
            p_error_code,
            SYSTIMESTAMP);
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('SP_LOG_ETL_RUN failed for ' || p_procedure_name || '/' || p_step_name || ': ' || SQLERRM);
END sp_log_etl_run;
/
