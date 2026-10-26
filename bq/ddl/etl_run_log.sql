CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.etl_run_log` (
  log_id         INT64,             -- NOTE: Oracle identity column (ISEQ$$_73552); not populated by sp_log_etl_run in BigQuery
  run_id         INT64     NOT NULL,
  procedure_name STRING    NOT NULL,
  step_name      STRING    NOT NULL,
  status         STRING    NOT NULL,
  rows_affected  INT64,
  message        STRING,
  error_code     INT64,
  log_ts         TIMESTAMP DEFAULT CURRENT_TIMESTAMP() NOT NULL
)
PARTITION BY DATE(log_ts)
CLUSTER BY procedure_name, run_id;
-- NOTE: PK_ETL_RUN_LOG PRIMARY KEY (log_id) not enforced
-- NOTE: CK_ETL_RUN_LOG_STATUS CHECK (status IN ('STARTED','SUCCESS','FAILED','WARNING','INFO'))
-- NOTE: indexes IX_ETL_RUN_LOG_PROC (procedure_name, log_ts), IX_ETL_RUN_LOG_RUN (run_id) dropped
