CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_CALC_CUSTOMER_SEGMENTS" (
    p_as_of_date       IN DATE     DEFAULT TRUNC(SYSDATE),
    p_lookback_months  IN NUMBER   DEFAULT 12,
    p_target_table     IN VARCHAR2 DEFAULT 'CUSTOMER_SEGMENTS'
)
AS
    c_proc CONSTANT VARCHAR2(30) := 'SP_CALC_CUSTOMER_SEGMENTS';

    v_run_id        NUMBER := etl_run_seq.NEXTVAL;
    v_as_of         DATE;
    v_window_start  DATE;
    v_table         VARCHAR2(128);
    v_table_count   PLS_INTEGER;
    v_sql           VARCHAR2(32767);
    v_merged        PLS_INTEGER := 0;
    v_tier_changes  PLS_INTEGER := 0;
    v_seg_changes   PLS_INTEGER := 0;
    v_distribution  VARCHAR2(4000);
BEGIN
    IF p_as_of_date IS NULL OR p_lookback_months IS NULL OR p_lookback_months NOT BETWEEN 1 AND 36 THEN
        RAISE_APPLICATION_ERROR(-20501, 'Invalid parameters: p_as_of_date=' || TO_CHAR(p_as_of_date, 'YYYY-MM-DD')
                                        || ', p_lookback_months=' || p_lookback_months);
    END IF;

    -- Guard the dynamic table name against SQL injection, then check it exists
    v_table := UPPER(DBMS_ASSERT.SIMPLE_SQL_NAME(p_target_table));
    SELECT COUNT(*) INTO v_table_count FROM user_tables WHERE table_name = v_table;
    IF v_table_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20502, 'Target table ' || v_table || ' does not exist');
    END IF;

    v_as_of        := TRUNC(p_as_of_date);
    v_window_start := ADD_MONTHS(v_as_of, -p_lookback_months);
    sp_log_etl_run(v_run_id, c_proc, 'START', 'STARTED', NULL,
                   'as_of=' || TO_CHAR(v_as_of, 'YYYY-MM-DD') || ' window_start=' || TO_CHAR(v_window_start, 'YYYY-MM-DD')
                   || ' target=' || v_table);

    -- Steps 1-3: score, segment and upsert
    v_sql := q'[
        MERGE INTO #TARGET# tgt
        USING (
            WITH order_value AS (
                SELECT o.order_id,
                       o.customer_id,
                       TRUNC(o.order_date) AS order_day,
                       SUM(oi.line_total)  AS items_value
                FROM orders o
                JOIN order_items oi ON oi.order_id = o.order_id
                WHERE o.order_date >= :window_start
                  AND o.order_date <  :as_of_1
                  AND o.order_status <> 'CANCELLED'
                  AND o.dq_status <> 'FAILED'
                GROUP BY o.order_id, o.customer_id, TRUNC(o.order_date)
            ),
            refunds AS (
                SELECT order_id, SUM(refund_amount) AS refund_amount
                FROM order_returns
                WHERE return_status = 'PROCESSED'
                GROUP BY order_id
            ),
            activity AS (
                SELECT ov.customer_id,
                       :as_of_2 - MAX(ov.order_day)                     AS recency_days,
                       COUNT(*)                                         AS frequency,
                       SUM(ov.items_value - NVL(rf.refund_amount, 0))   AS monetary
                FROM order_value ov
                LEFT JOIN refunds rf ON rf.order_id = ov.order_id
                GROUP BY ov.customer_id
            ),
            scored AS (
                SELECT a.*,
                       NTILE(5) OVER (ORDER BY a.recency_days DESC)      AS r_score,
                       NTILE(5) OVER (ORDER BY a.frequency, a.monetary)  AS f_score,
                       NTILE(5) OVER (ORDER BY a.monetary)               AS m_score
                FROM activity a
            )
            SELECT c.customer_id,
                   s.recency_days,
                   NVL(s.frequency, 0)  AS frequency,
                   NVL(s.monetary, 0)   AS monetary,
                   NVL(s.r_score, 0)    AS r_score,
                   NVL(s.f_score, 0)    AS f_score,
                   NVL(s.m_score, 0)    AS m_score,
                   CASE WHEN s.customer_id IS NOT NULL THEN s.r_score || s.f_score || s.m_score END AS rfm_code,
                   CASE
                       WHEN s.customer_id IS NULL                                THEN 'INACTIVE'
                       WHEN s.r_score >= 4 AND s.f_score >= 4 AND s.m_score >= 4 THEN 'CHAMPIONS'
                       WHEN s.r_score >= 3 AND s.f_score >= 3                    THEN 'LOYAL'
                       WHEN s.r_score >= 4 AND s.f_score <= 2                    THEN 'NEW_OR_PROMISING'
                       WHEN s.r_score <= 2 AND s.f_score >= 4                    THEN 'CANT_LOSE'
                       WHEN s.r_score <= 2 AND s.f_score >= 2                    THEN 'AT_RISK'
                       WHEN s.r_score = 1                                        THEN 'HIBERNATING'
                       ELSE 'NEEDS_ATTENTION'
                   END AS segment_name
            FROM customers c
            LEFT JOIN scored s ON s.customer_id = c.customer_id
            WHERE c.signup_date < :as_of_3
        ) src
        ON (tgt.customer_id = src.customer_id)
        WHEN MATCHED THEN
            UPDATE SET tgt.prev_segment_name  = CASE WHEN tgt.segment_name <> src.segment_name
                                                     THEN tgt.segment_name ELSE tgt.prev_segment_name END,
                       tgt.segment_changed_on = CASE WHEN tgt.segment_name <> src.segment_name
                                                     THEN :as_of_4 ELSE tgt.segment_changed_on END,
                       tgt.as_of_date         = :as_of_5,
                       tgt.recency_days       = src.recency_days,
                       tgt.frequency          = src.frequency,
                       tgt.monetary           = src.monetary,
                       tgt.r_score            = src.r_score,
                       tgt.f_score            = src.f_score,
                       tgt.m_score            = src.m_score,
                       tgt.rfm_code           = src.rfm_code,
                       tgt.segment_name       = src.segment_name,
                       tgt.load_ts            = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (customer_id, as_of_date, recency_days, frequency, monetary, r_score, f_score, m_score,
                    rfm_code, segment_name, prev_segment_name, segment_changed_on, load_ts)
            VALUES (src.customer_id, :as_of_6, src.recency_days, src.frequency, src.monetary,
                    src.r_score, src.f_score, src.m_score, src.rfm_code, src.segment_name,
                    NULL, :as_of_7, SYSTIMESTAMP)]';
    v_sql := REPLACE(v_sql, '#TARGET#', v_table);

    -- Positional binds: one value per placeholder occurrence
    EXECUTE IMMEDIATE v_sql
        USING v_window_start, v_as_of, v_as_of, v_as_of, v_as_of, v_as_of, v_as_of, v_as_of;
    v_merged := SQL%ROWCOUNT;

    -- Step 4: loyalty tiers follow the production segment table only
    IF v_table = 'CUSTOMER_SEGMENTS' THEN
        MERGE INTO customers c
        USING (
            SELECT customer_id,
                   CASE
                       WHEN segment_name = 'CHAMPIONS' OR monetary >= 5000            THEN 'PLATINUM'
                       WHEN segment_name IN ('LOYAL', 'CANT_LOSE') OR monetary >= 2000 THEN 'GOLD'
                       WHEN frequency >= 2                                             THEN 'SILVER'
                       ELSE 'BRONZE'
                   END AS new_tier
            FROM customer_segments
            WHERE as_of_date = v_as_of
        ) s
        ON (c.customer_id = s.customer_id)
        WHEN MATCHED THEN
            UPDATE SET c.loyalty_tier = s.new_tier,
                       c.updated_at   = SYSTIMESTAMP
            WHERE c.loyalty_tier <> s.new_tier;
        v_tier_changes := SQL%ROWCOUNT;
    END IF;

    -- Step 5: distribution summary for the run log
    EXECUTE IMMEDIATE
        'SELECT LISTAGG(segment_name || ''='' || cnt, '', '') WITHIN GROUP (ORDER BY cnt DESC, segment_name)'
        || ' FROM (SELECT segment_name, COUNT(*) AS cnt FROM ' || v_table
        || ' WHERE as_of_date = :1 GROUP BY segment_name)'
        INTO v_distribution
        USING v_as_of;

    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_table || ' WHERE segment_changed_on = :1'
        INTO v_seg_changes
        USING v_as_of;

    COMMIT;

    sp_log_etl_run(v_run_id, c_proc, 'DISTRIBUTION', 'INFO', v_merged, v_distribution);
    sp_log_etl_run(v_run_id, c_proc, 'END', 'SUCCESS', v_merged,
                   'customers=' || v_merged || ' segment_changes=' || v_seg_changes
                   || ' tier_changes=' || v_tier_changes);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', NULL,
                       SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SQLCODE);
        RAISE;
END sp_calc_customer_segments;
/
