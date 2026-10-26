CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_GENERATE_REORDER_ALERTS" (
    p_run_date    IN DATE        DEFAULT TRUNC(SYSDATE) - 1,
    p_max_alerts  IN PLS_INTEGER DEFAULT 200,
    p_cover_days  IN PLS_INTEGER DEFAULT 30
)
AS
    c_proc       CONSTANT VARCHAR2(30) := 'SP_GENERATE_REORDER_ALERTS';
    c_case_pack  CONSTANT PLS_INTEGER  := 10;
    c_max_uplift CONSTANT NUMBER       := 50;   -- cap on trend-based order uplift, %

    CURSOR c_candidates (cp_run_date DATE, cp_limit PLS_INTEGER) IS
        SELECT *
        FROM (
            SELECT d.product_id,
                   d.warehouse_id,
                   d.supplier_id,
                   d.qty_available,
                   d.avg_daily_28d,
                   d.avg_daily_prev_28d,
                   d.lead_time_days,
                   d.safety_stock,
                   d.dyn_reorder_point,
                   CASE WHEN d.avg_daily_28d > 0 THEN ROUND(d.qty_available / d.avg_daily_28d, 1) END AS days_of_cover
            FROM (
                SELECT inv.product_id,
                       inv.warehouse_id,
                       p.supplier_id,
                       inv.qty_on_hand - inv.qty_reserved                       AS qty_available,
                       NVL(dm.qty_28d, 0) / 28                                  AS avg_daily_28d,
                       NVL(dm.qty_prev_28d, 0) / 28                             AS avg_daily_prev_28d,
                       CEIL(sup.lead_time_days / sup.reliability_score)         AS lead_time_days,
                       inv.safety_stock,
                       CEIL(NVL(dm.qty_28d, 0) / 28 * CEIL(sup.lead_time_days / sup.reliability_score))
                           + inv.safety_stock                                   AS dyn_reorder_point
                FROM inventory inv
                JOIN products p    ON p.product_id = inv.product_id
                JOIN suppliers sup ON sup.supplier_id = p.supplier_id
                LEFT JOIN (
                    SELECT oi.product_id,
                           o.ship_warehouse_id AS warehouse_id,
                           SUM(CASE WHEN o.order_date >= cp_run_date - 27 THEN oi.quantity ELSE 0 END) AS qty_28d,
                           SUM(CASE WHEN o.order_date <  cp_run_date - 27 THEN oi.quantity ELSE 0 END) AS qty_prev_28d
                    FROM orders o
                    JOIN order_items oi ON oi.order_id = o.order_id
                    WHERE o.order_date >= cp_run_date - 55
                      AND o.order_date <  cp_run_date + 1
                      AND o.order_status <> 'CANCELLED'
                      AND o.ship_warehouse_id IS NOT NULL
                    GROUP BY oi.product_id, o.ship_warehouse_id
                ) dm
                  ON dm.product_id = inv.product_id
                 AND dm.warehouse_id = inv.warehouse_id
                WHERE p.is_discontinued = 'N'
                  AND sup.is_active = 'Y'
            ) d
            WHERE d.qty_available <= d.dyn_reorder_point
            ORDER BY CASE WHEN d.avg_daily_28d > 0 THEN d.qty_available / d.avg_daily_28d ELSE 999999 END,
                     d.qty_available,
                     d.product_id,
                     d.warehouse_id
        )
        WHERE ROWNUM <= cp_limit;

    TYPE t_cand_tab  IS TABLE OF c_candidates%ROWTYPE;
    TYPE t_alert_tab IS TABLE OF reorder_alerts%ROWTYPE;

    v_run_id      NUMBER := etl_run_seq.NEXTVAL;
    v_run_date    DATE;
    v_cands       t_cand_tab;
    v_alerts      t_alert_tab := t_alert_tab();
    v_trend       NUMBER;
    v_rec_qty     NUMBER;
    v_priority    reorder_alerts.priority%TYPE;
    v_deleted     PLS_INTEGER := 0;
    v_closed      PLS_INTEGER := 0;
    v_rop_updates PLS_INTEGER := 0;
    v_summary     VARCHAR2(400);
BEGIN
    IF p_run_date IS NULL OR NVL(p_max_alerts, 0) NOT BETWEEN 1 AND 5000 OR NVL(p_cover_days, 0) NOT BETWEEN 1 AND 180 THEN
        RAISE_APPLICATION_ERROR(-20601, 'Invalid parameters: p_max_alerts=' || p_max_alerts || ', p_cover_days=' || p_cover_days);
    END IF;
    v_run_date := TRUNC(p_run_date);
    sp_log_etl_run(v_run_id, c_proc, 'START', 'STARTED', NULL, 'run_date=' || TO_CHAR(v_run_date, 'YYYY-MM-DD'));

    -- Step 1: idempotent re-run, close alerts whose stock has recovered
    DELETE FROM reorder_alerts WHERE alert_date = v_run_date;
    v_deleted := SQL%ROWCOUNT;

    UPDATE reorder_alerts a
    SET a.alert_status = 'CLOSED',
        a.closed_at    = SYSTIMESTAMP
    WHERE a.alert_status IN ('OPEN', 'ACKNOWLEDGED')
      AND EXISTS (SELECT 1
                  FROM inventory i
                  WHERE i.product_id = a.product_id
                    AND i.warehouse_id = a.warehouse_id
                    AND i.qty_on_hand - i.qty_reserved > a.reorder_point);
    v_closed := SQL%ROWCOUNT;

    -- Steps 2-4: candidates, most urgent first
    OPEN c_candidates(v_run_date, p_max_alerts);
    FETCH c_candidates BULK COLLECT INTO v_cands;
    CLOSE c_candidates;

    -- Step 5: size the order and set priority
    FOR i IN 1 .. v_cands.COUNT LOOP
        v_trend := CASE
                       WHEN v_cands(i).avg_daily_prev_28d > 0
                       THEN ROUND((v_cands(i).avg_daily_28d - v_cands(i).avg_daily_prev_28d)
                                  / v_cands(i).avg_daily_prev_28d * 100, 2)
                   END;

        -- cover lead time + p_cover_days of demand, with uplift when demand is growing
        v_rec_qty := v_cands(i).avg_daily_28d
                     * (1 + LEAST(GREATEST(NVL(v_trend, 0), 0), c_max_uplift) / 100)
                     * (v_cands(i).lead_time_days + p_cover_days)
                     + v_cands(i).safety_stock
                     - v_cands(i).qty_available;
        v_rec_qty := GREATEST(CEIL(v_rec_qty / c_case_pack) * c_case_pack, c_case_pack);

        v_priority := CASE
                          WHEN v_cands(i).qty_available <= 0                                THEN 'CRITICAL'
                          WHEN v_cands(i).days_of_cover < v_cands(i).lead_time_days / 2     THEN 'CRITICAL'
                          WHEN v_cands(i).days_of_cover < v_cands(i).lead_time_days
                            OR v_cands(i).qty_available < v_cands(i).safety_stock           THEN 'HIGH'
                          ELSE 'MEDIUM'
                      END;

        v_alerts.EXTEND;
        v_alerts(i).alert_id             := NULL;   -- identity (ON NULL)
        v_alerts(i).alert_date           := v_run_date;
        v_alerts(i).product_id           := v_cands(i).product_id;
        v_alerts(i).warehouse_id         := v_cands(i).warehouse_id;
        v_alerts(i).supplier_id          := v_cands(i).supplier_id;
        v_alerts(i).qty_available        := v_cands(i).qty_available;
        v_alerts(i).avg_daily_demand_28d := ROUND(v_cands(i).avg_daily_28d, 3);
        v_alerts(i).demand_trend_pct     := v_trend;
        v_alerts(i).days_of_cover        := v_cands(i).days_of_cover;
        v_alerts(i).lead_time_days       := v_cands(i).lead_time_days;
        v_alerts(i).reorder_point        := v_cands(i).dyn_reorder_point;
        v_alerts(i).recommended_qty      := v_rec_qty;
        v_alerts(i).priority             := v_priority;
        v_alerts(i).priority_rank        := i;
        v_alerts(i).alert_status         := 'OPEN';
        v_alerts(i).created_at           := SYSTIMESTAMP;
        v_alerts(i).closed_at            := NULL;
    END LOOP;

    FORALL i IN 1 .. v_alerts.COUNT
        INSERT INTO reorder_alerts VALUES v_alerts(i);

    -- Step 6: keep the dynamic reorder point on the inventory row
    FORALL i IN 1 .. v_cands.COUNT
        UPDATE inventory
        SET reorder_point = v_cands(i).dyn_reorder_point,
            last_updated  = SYSTIMESTAMP
        WHERE product_id   = v_cands(i).product_id
          AND warehouse_id = v_cands(i).warehouse_id
          AND reorder_point <> v_cands(i).dyn_reorder_point;
    v_rop_updates := SQL%ROWCOUNT;

    SELECT LISTAGG(priority || '=' || cnt, ', ') WITHIN GROUP (ORDER BY DECODE(priority, 'CRITICAL', 1, 'HIGH', 2, 3))
    INTO v_summary
    FROM (SELECT priority, COUNT(*) AS cnt
          FROM reorder_alerts
          WHERE alert_date = v_run_date
          GROUP BY priority);

    COMMIT;

    sp_log_etl_run(v_run_id, c_proc, 'END', 'SUCCESS', v_alerts.COUNT,
                   'alerts=' || v_alerts.COUNT || ' (' || NVL(v_summary, 'none') || ')'
                   || ' replaced=' || v_deleted || ' closed=' || v_closed || ' reorder_point_updates=' || v_rop_updates);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        IF c_candidates%ISOPEN THEN
            CLOSE c_candidates;
        END IF;
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', NULL,
                       SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SQLCODE);
        RAISE;
END sp_generate_reorder_alerts;
/
