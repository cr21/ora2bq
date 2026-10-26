CREATE OR REPLACE PROCEDURE `project-5c016d48-80d5-4534-b69.orc_dataset.sp_build_daily_sales_summary`(
  p_run_date  DATE,
  p_days_back INT64
)
BEGIN
  DECLARE c_proc        STRING DEFAULT 'SP_BUILD_DAILY_SALES_SUMMARY';
  DECLARE v_run_date    DATE;
  DECLARE v_days_back   INT64;
  DECLARE v_run_id      INT64;
  DECLARE v_load_ts     TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE v_from        DATE;
  DECLARE v_to          DATE;  -- exclusive
  DECLARE v_merged      INT64 DEFAULT 0;
  DECLARE v_deleted     INT64 DEFAULT 0;
  DECLARE v_mtd_rows    INT64 DEFAULT 0;
  DECLARE v_summary_net NUMERIC;
  DECLARE v_source_net  NUMERIC;
  DECLARE v_err_code    INT64;
  DECLARE v_in_txn      BOOL DEFAULT FALSE;

  -- NOTE: etl_run_seq.NEXTVAL replaced by MAX(run_id)+1 over etl_run_log (floor 1011 matches Oracle START WITH 1012).
  --       Not safe if two ETL procedures start at the same instant.
  SET v_run_id = (SELECT IFNULL(MAX(run_id), 1011) + 1 FROM `project-5c016d48-80d5-4534-b69.orc_dataset.etl_run_log`);

  BEGIN
    -- NOTE: Oracle defaults (TRUNC(SYSDATE)-1, 3) applied when NULL is passed, since BigQuery has no parameter defaults.
    --       In Oracle an explicit NULL p_run_date raised -20401; here it means "yesterday". CURRENT_DATE() is UTC.
    SET v_run_date  = IFNULL(p_run_date, DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY));
    SET v_days_back = IFNULL(p_days_back, 3);

    IF v_run_date > CURRENT_DATE() THEN
      SET v_err_code = -20401;
      RAISE USING MESSAGE = CONCAT('p_run_date must be today or earlier, got ', FORMAT_DATE('%Y-%m-%d', v_run_date));
    END IF;
    IF v_days_back NOT BETWEEN 1 AND 730 THEN
      SET v_err_code = -20402;
      RAISE USING MESSAGE = CONCAT('p_days_back must be between 1 and 730, got ', CAST(v_days_back AS STRING));
    END IF;

    SET v_to   = DATE_ADD(v_run_date, INTERVAL 1 DAY);
    SET v_from = DATE_SUB(v_to, INTERVAL v_days_back DAY);
    CALL `project-5c016d48-80d5-4534-b69.orc_dataset.sp_log_etl_run`(v_run_id, c_proc, 'START', 'STARTED', NULL,
      CONCAT('Window ', FORMAT_DATE('%Y-%m-%d', v_from), ' to ', FORMAT_DATE('%Y-%m-%d', DATE_SUB(v_to, INTERVAL 1 DAY))), NULL);

    -- NOTE: CONNECT BY / CONNECT_BY_ROOT rewritten as a recursive CTE, materialized in a script temp table
    --       because BigQuery only allows WITH RECURSIVE at the top level of a query.
    CREATE OR REPLACE TEMP TABLE cat_root AS
    WITH RECURSIVE cr AS (
      SELECT category_id,
             category_id   AS top_category_id,
             category_name AS top_category_name
      FROM `project-5c016d48-80d5-4534-b69.orc_dataset.product_categories`
      WHERE parent_category_id IS NULL
      UNION ALL
      SELECT pc.category_id, cr.top_category_id, cr.top_category_name
      FROM `project-5c016d48-80d5-4534-b69.orc_dataset.product_categories` pc
      JOIN cr ON pc.parent_category_id = cr.category_id
    )
    SELECT * FROM cr;

    -- NOTE: Oracle COMMIT/ROLLBACK replaced by an explicit transaction so steps 1-4 stay atomic.
    BEGIN TRANSACTION;
    SET v_in_txn = TRUE;

    -- Steps 1-3: aggregate and upsert
    MERGE `project-5c016d48-80d5-4534-b69.orc_dataset.daily_sales_summary` tgt
    USING (
      WITH
      sales AS (
        SELECT DATE(o.order_date)                               AS summary_date,
               c.region,
               cr.top_category_id,
               cr.top_category_name,
               o.channel,
               COUNT(DISTINCT o.order_id)                       AS order_count,
               SUM(oi.quantity)                                 AS units_sold,
               SUM(oi.quantity * oi.unit_price)                 AS gross_sales,
               SUM(oi.quantity * oi.unit_price - oi.line_total) AS discount_total,
               SUM(oi.line_total)                               AS net_sales,
               SUM(oi.quantity * p.unit_cost)                   AS cogs
        FROM `project-5c016d48-80d5-4534-b69.orc_dataset.orders` o
        JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.customers` c    ON c.customer_id = o.customer_id
        JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.order_items` oi ON oi.order_id = o.order_id
        JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.products` p     ON p.product_id = oi.product_id
        JOIN cat_root cr           ON cr.category_id = p.category_id
        WHERE o.order_date >= DATETIME(v_from)
          AND o.order_date <  DATETIME(v_to)
          AND o.order_status <> 'CANCELLED'
          AND o.dq_status <> 'FAILED'
        GROUP BY summary_date, c.region, cr.top_category_id, cr.top_category_name, o.channel
      ),
      rets AS (
        SELECT r.return_date                   AS summary_date,
               c.region,
               cr.top_category_id,
               cr.top_category_name,
               o.channel,
               SUM(r.quantity)                 AS return_units,
               SUM(IFNULL(r.refund_amount, 0)) AS refund_total
        FROM `project-5c016d48-80d5-4534-b69.orc_dataset.order_returns` r
        JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.orders` o    ON o.order_id = r.order_id
        JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.customers` c ON c.customer_id = o.customer_id
        JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.products` p  ON p.product_id = r.product_id
        JOIN cat_root cr        ON cr.category_id = p.category_id
        WHERE r.return_date >= v_from
          AND r.return_date <  v_to
          AND r.return_status = 'PROCESSED'
        GROUP BY r.return_date, c.region, cr.top_category_id, cr.top_category_name, o.channel
      )
      SELECT IFNULL(s.summary_date, x.summary_date)           AS summary_date,
             IFNULL(s.region, x.region)                       AS region,
             IFNULL(s.top_category_id, x.top_category_id)     AS top_category_id,
             IFNULL(s.top_category_name, x.top_category_name) AS top_category_name,
             IFNULL(s.channel, x.channel)                     AS channel,
             IFNULL(s.order_count, 0)                         AS order_count,
             IFNULL(s.units_sold, 0)                          AS units_sold,
             IFNULL(s.gross_sales, 0)                         AS gross_sales,
             IFNULL(s.discount_total, 0)                      AS discount_total,
             IFNULL(s.net_sales, 0)                           AS net_sales,
             IFNULL(s.cogs, 0)                                AS cogs,
             IFNULL(x.return_units, 0)                        AS return_units,
             IFNULL(x.refund_total, 0)                        AS refund_total
      FROM sales s
      FULL OUTER JOIN rets x
        ON  x.summary_date    = s.summary_date
        AND x.region          = s.region
        AND x.top_category_id = s.top_category_id
        AND x.channel         = s.channel
    ) src
    ON  tgt.summary_date    = src.summary_date
    AND tgt.region          = src.region
    AND tgt.top_category_id = src.top_category_id
    AND tgt.channel         = src.channel
    WHEN MATCHED THEN
      UPDATE SET top_category_name = src.top_category_name,
                 order_count       = src.order_count,
                 units_sold        = src.units_sold,
                 gross_sales       = src.gross_sales,
                 discount_total    = src.discount_total,
                 net_sales         = src.net_sales,
                 cogs              = src.cogs,
                 gross_margin      = src.net_sales - src.cogs,
                 margin_pct        = ROUND((src.net_sales - src.cogs) / NULLIF(src.net_sales, 0) * 100, 2),
                 avg_order_value   = ROUND(src.net_sales / NULLIF(src.order_count, 0), 2),
                 return_units      = src.return_units,
                 refund_total      = src.refund_total,
                 load_ts           = v_load_ts
    WHEN NOT MATCHED THEN
      INSERT (summary_date, region, top_category_id, top_category_name, channel,
              order_count, units_sold, gross_sales, discount_total, net_sales, cogs,
              gross_margin, margin_pct, avg_order_value, return_units, refund_total, load_ts)
      VALUES (src.summary_date, src.region, src.top_category_id, src.top_category_name, src.channel,
              src.order_count, src.units_sold, src.gross_sales, src.discount_total, src.net_sales, src.cogs,
              src.net_sales - src.cogs,
              ROUND((src.net_sales - src.cogs) / NULLIF(src.net_sales, 0) * 100, 2),
              ROUND(src.net_sales / NULLIF(src.order_count, 0), 2),
              src.return_units, src.refund_total, v_load_ts);
    SET v_merged = @@row_count;

    -- Rows in the window that the source no longer produces (e.g. order failed DQ after the last run)
    DELETE FROM `project-5c016d48-80d5-4534-b69.orc_dataset.daily_sales_summary`
    WHERE summary_date >= v_from
      AND summary_date <  v_to
      AND load_ts < v_load_ts;
    SET v_deleted = @@row_count;

    -- Step 4: month-to-date net sales (window start onwards, so later days of the month stay correct)
    -- NOTE: correlated self-subquery rewritten as UPDATE ... FROM with a running SUM per month.
    UPDATE `project-5c016d48-80d5-4534-b69.orc_dataset.daily_sales_summary` t
    SET mtd_net_sales = m.mtd_net_sales
    FROM (
      SELECT summary_date, region, top_category_id, channel,
             SUM(net_sales) OVER (
               PARTITION BY region, top_category_id, channel, DATE_TRUNC(summary_date, MONTH)
               ORDER BY summary_date
             ) AS mtd_net_sales
      FROM `project-5c016d48-80d5-4534-b69.orc_dataset.daily_sales_summary`
      WHERE summary_date >= DATE_TRUNC(v_from, MONTH)
    ) m
    WHERE t.summary_date    = m.summary_date
      AND t.region          = m.region
      AND t.top_category_id = m.top_category_id
      AND t.channel         = m.channel
      AND t.summary_date   >= DATE_TRUNC(v_from, MONTH);
    SET v_mtd_rows = @@row_count;

    -- Step 5: reconciliation against source
    SET v_summary_net = (
      SELECT IFNULL(SUM(net_sales), 0)
      FROM `project-5c016d48-80d5-4534-b69.orc_dataset.daily_sales_summary`
      WHERE summary_date >= v_from
        AND summary_date <  v_to
    );

    SET v_source_net = (
      SELECT IFNULL(SUM(oi.line_total), 0)
      FROM `project-5c016d48-80d5-4534-b69.orc_dataset.orders` o
      JOIN `project-5c016d48-80d5-4534-b69.orc_dataset.order_items` oi ON oi.order_id = o.order_id
      WHERE o.order_date >= DATETIME(v_from)
        AND o.order_date <  DATETIME(v_to)
        AND o.order_status <> 'CANCELLED'
        AND o.dq_status <> 'FAILED'
    );

    COMMIT TRANSACTION;
    SET v_in_txn = FALSE;

    IF ABS(v_summary_net - v_source_net) > 0.01 THEN
      CALL `project-5c016d48-80d5-4534-b69.orc_dataset.sp_log_etl_run`(v_run_id, c_proc, 'RECONCILE', 'WARNING', NULL,
        CONCAT('summary_net=', CAST(v_summary_net AS STRING), ' source_net=', CAST(v_source_net AS STRING)), NULL);
    END IF;

    CALL `project-5c016d48-80d5-4534-b69.orc_dataset.sp_log_etl_run`(v_run_id, c_proc, 'END', 'SUCCESS', v_merged,
      CONCAT('merged=', CAST(v_merged AS STRING), ' deleted=', CAST(v_deleted AS STRING),
             ' mtd_rows=', CAST(v_mtd_rows AS STRING), ' net_sales=', FORMAT('%.2f', v_summary_net)), NULL);
  EXCEPTION WHEN ERROR THEN
    IF v_in_txn THEN
      ROLLBACK TRANSACTION;
    END IF;
    -- NOTE: SQLERRM/FORMAT_ERROR_BACKTRACE -> @@error.message/formatted_stack_trace. SQLCODE has no equivalent:
    --       error_code is logged only for this procedure's own validation errors (-20401/-20402).
    CALL `project-5c016d48-80d5-4534-b69.orc_dataset.sp_log_etl_run`(v_run_id, c_proc, 'END', 'FAILED', NULL,
      CONCAT(@@error.message, ' | ', IFNULL(@@error.formatted_stack_trace, '')), v_err_code);
    RAISE;
  END;
END;
