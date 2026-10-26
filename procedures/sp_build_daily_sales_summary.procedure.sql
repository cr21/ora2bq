CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_BUILD_DAILY_SALES_SUMMARY" (
    p_run_date   IN DATE   DEFAULT TRUNC(SYSDATE) - 1,
    p_days_back  IN NUMBER DEFAULT 3
)
AS
    c_proc CONSTANT VARCHAR2(30) := 'SP_BUILD_DAILY_SALES_SUMMARY';

    v_run_id      NUMBER    := etl_run_seq.NEXTVAL;
    v_load_ts     TIMESTAMP := SYSTIMESTAMP;
    v_from        DATE;
    v_to          DATE;      -- exclusive
    v_merged      PLS_INTEGER := 0;
    v_deleted     PLS_INTEGER := 0;
    v_mtd_rows    PLS_INTEGER := 0;
    v_summary_net NUMBER;
    v_source_net  NUMBER;
BEGIN
    IF p_run_date IS NULL OR TRUNC(p_run_date) > TRUNC(SYSDATE) THEN
        RAISE_APPLICATION_ERROR(-20401, 'p_run_date must be today or earlier, got ' || TO_CHAR(p_run_date, 'YYYY-MM-DD'));
    END IF;
    IF p_days_back IS NULL OR p_days_back NOT BETWEEN 1 AND 730 THEN
        RAISE_APPLICATION_ERROR(-20402, 'p_days_back must be between 1 and 730, got ' || p_days_back);
    END IF;

    v_to   := TRUNC(p_run_date) + 1;
    v_from := v_to - p_days_back;
    sp_log_etl_run(v_run_id, c_proc, 'START', 'STARTED', NULL,
                   'Window ' || TO_CHAR(v_from, 'YYYY-MM-DD') || ' to ' || TO_CHAR(v_to - 1, 'YYYY-MM-DD'));

    -- Steps 1-3: aggregate and upsert
    MERGE INTO daily_sales_summary tgt
    USING (
        WITH cat_root AS (
            SELECT category_id,
                   CONNECT_BY_ROOT category_id   AS top_category_id,
                   CONNECT_BY_ROOT category_name AS top_category_name
            FROM product_categories
            START WITH parent_category_id IS NULL
            CONNECT BY PRIOR category_id = parent_category_id
        ),
        sales AS (
            SELECT TRUNC(o.order_date)                         AS summary_date,
                   c.region,
                   cr.top_category_id,
                   cr.top_category_name,
                   o.channel,
                   COUNT(DISTINCT o.order_id)                  AS order_count,
                   SUM(oi.quantity)                            AS units_sold,
                   SUM(oi.quantity * oi.unit_price)            AS gross_sales,
                   SUM(oi.quantity * oi.unit_price - oi.line_total) AS discount_total,
                   SUM(oi.line_total)                          AS net_sales,
                   SUM(oi.quantity * p.unit_cost)              AS cogs
            FROM orders o
            JOIN customers c    ON c.customer_id = o.customer_id
            JOIN order_items oi ON oi.order_id = o.order_id
            JOIN products p     ON p.product_id = oi.product_id
            JOIN cat_root cr    ON cr.category_id = p.category_id
            WHERE o.order_date >= v_from
              AND o.order_date <  v_to
              AND o.order_status <> 'CANCELLED'
              AND o.dq_status <> 'FAILED'
            GROUP BY TRUNC(o.order_date), c.region, cr.top_category_id, cr.top_category_name, o.channel
        ),
        rets AS (
            SELECT r.return_date                  AS summary_date,
                   c.region,
                   cr.top_category_id,
                   cr.top_category_name,
                   o.channel,
                   SUM(r.quantity)                AS return_units,
                   SUM(NVL(r.refund_amount, 0))   AS refund_total
            FROM order_returns r
            JOIN orders o    ON o.order_id = r.order_id
            JOIN customers c ON c.customer_id = o.customer_id
            JOIN products p  ON p.product_id = r.product_id
            JOIN cat_root cr ON cr.category_id = p.category_id
            WHERE r.return_date >= v_from
              AND r.return_date <  v_to
              AND r.return_status = 'PROCESSED'
            GROUP BY r.return_date, c.region, cr.top_category_id, cr.top_category_name, o.channel
        )
        SELECT NVL(s.summary_date, x.summary_date)           AS summary_date,
               NVL(s.region, x.region)                       AS region,
               NVL(s.top_category_id, x.top_category_id)     AS top_category_id,
               NVL(s.top_category_name, x.top_category_name) AS top_category_name,
               NVL(s.channel, x.channel)                     AS channel,
               NVL(s.order_count, 0)                         AS order_count,
               NVL(s.units_sold, 0)                          AS units_sold,
               NVL(s.gross_sales, 0)                         AS gross_sales,
               NVL(s.discount_total, 0)                      AS discount_total,
               NVL(s.net_sales, 0)                           AS net_sales,
               NVL(s.cogs, 0)                                AS cogs,
               NVL(x.return_units, 0)                        AS return_units,
               NVL(x.refund_total, 0)                        AS refund_total
        FROM sales s
        FULL OUTER JOIN rets x
          ON  x.summary_date    = s.summary_date
          AND x.region          = s.region
          AND x.top_category_id = s.top_category_id
          AND x.channel         = s.channel
    ) src
    ON (    tgt.summary_date    = src.summary_date
        AND tgt.region          = src.region
        AND tgt.top_category_id = src.top_category_id
        AND tgt.channel         = src.channel)
    WHEN MATCHED THEN
        UPDATE SET tgt.top_category_name = src.top_category_name,
                   tgt.order_count       = src.order_count,
                   tgt.units_sold        = src.units_sold,
                   tgt.gross_sales       = src.gross_sales,
                   tgt.discount_total    = src.discount_total,
                   tgt.net_sales         = src.net_sales,
                   tgt.cogs              = src.cogs,
                   tgt.gross_margin      = src.net_sales - src.cogs,
                   tgt.margin_pct        = ROUND((src.net_sales - src.cogs) / NULLIF(src.net_sales, 0) * 100, 2),
                   tgt.avg_order_value   = ROUND(src.net_sales / NULLIF(src.order_count, 0), 2),
                   tgt.return_units      = src.return_units,
                   tgt.refund_total      = src.refund_total,
                   tgt.load_ts           = v_load_ts
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
    v_merged := SQL%ROWCOUNT;

    -- Rows in the window that the source no longer produces (e.g. order failed DQ after the last run)
    DELETE FROM daily_sales_summary
    WHERE summary_date >= v_from
      AND summary_date <  v_to
      AND load_ts < v_load_ts;
    v_deleted := SQL%ROWCOUNT;

    -- Step 4: month-to-date net sales (window start onwards, so later days of the month stay correct)
    UPDATE daily_sales_summary t
    SET t.mtd_net_sales = (SELECT SUM(m.net_sales)
                           FROM daily_sales_summary m
                           WHERE m.region          = t.region
                             AND m.top_category_id = t.top_category_id
                             AND m.channel         = t.channel
                             AND m.summary_date   >= TRUNC(t.summary_date, 'MM')
                             AND m.summary_date   <= t.summary_date)
    WHERE t.summary_date >= TRUNC(v_from, 'MM');
    v_mtd_rows := SQL%ROWCOUNT;

    -- Step 5: reconciliation against source
    SELECT NVL(SUM(net_sales), 0)
    INTO v_summary_net
    FROM daily_sales_summary
    WHERE summary_date >= v_from
      AND summary_date <  v_to;

    SELECT NVL(SUM(oi.line_total), 0)
    INTO v_source_net
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_date >= v_from
      AND o.order_date <  v_to
      AND o.order_status <> 'CANCELLED'
      AND o.dq_status <> 'FAILED';

    COMMIT;

    IF ABS(v_summary_net - v_source_net) > 0.01 THEN
        sp_log_etl_run(v_run_id, c_proc, 'RECONCILE', 'WARNING', NULL,
                       'summary_net=' || v_summary_net || ' source_net=' || v_source_net);
    END IF;

    sp_log_etl_run(v_run_id, c_proc, 'END', 'SUCCESS', v_merged,
                   'merged=' || v_merged || ' deleted=' || v_deleted || ' mtd_rows=' || v_mtd_rows
                   || ' net_sales=' || TO_CHAR(v_summary_net, 'FM999999999990.00'));
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', NULL,
                       SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SQLCODE);
        RAISE;
END sp_build_daily_sales_summary;
/
