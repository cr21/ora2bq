"""Daily rebuild of daily_sales_summary via the BigQuery procedure sp_build_daily_sales_summary.

Runs at 02:00 UTC. p_run_date is the logical date ({{ ds }}), i.e. the previous UTC day,
matching the Oracle default of TRUNC(SYSDATE) - 1. p_days_back=3 re-aggregates the last
three days to pick up late returns and DQ changes.
"""

from datetime import timedelta

import pendulum
from airflow import DAG
from airflow.providers.google.cloud.operators.bigquery import BigQueryInsertJobOperator

PROC = "`project-5c016d48-80d5-4534-b69.orc_dataset.sp_build_daily_sales_summary`"

with DAG(
    dag_id="sp_build_daily_sales_summary_daily",
    schedule="0 2 * * *",
    start_date=pendulum.datetime(2026, 10, 25, tz="UTC"),
    catchup=False,
    default_args={"retries": 2, "retry_delay": timedelta(minutes=5)},
    tags=["ora2bq", "sp_build_daily_sales_summary"],
) as dag:
    BigQueryInsertJobOperator(
        task_id="call_sp_build_daily_sales_summary",
        location="US",
        configuration={
            "query": {
                "query": f"CALL {PROC}(DATE '{{{{ ds }}}}', 3)",
                "useLegacySql": False,
            }
        },
    )
