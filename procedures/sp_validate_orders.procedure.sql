CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_VALIDATE_ORDERS" (
    p_run_date       IN DATE        DEFAULT TRUNC(SYSDATE) - 1,
    p_lookback_days  IN NUMBER      DEFAULT 7,
    p_max_fail_pct   IN NUMBER      DEFAULT 5,
    p_commit_every   IN PLS_INTEGER DEFAULT 1000
)
AS
    c_proc CONSTANT VARCHAR2(30) := 'SP_VALIDATE_ORDERS';

    e_no_items          EXCEPTION;
    e_total_mismatch    EXCEPTION;
    e_payment_mismatch  EXCEPTION;
    e_fail_threshold    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_fail_threshold, -20199);

    TYPE t_wh_map IS TABLE OF warehouses.warehouse_id%TYPE INDEX BY VARCHAR2(12);
    v_default_wh  t_wh_map;

    v_run_id      NUMBER := etl_run_seq.NEXTVAL;
    v_from_date   DATE;
    v_to_date     DATE;
    v_dq_status   orders.dq_status%TYPE;
    v_dq_message  VARCHAR2(400);
    v_new_status  orders.order_status%TYPE;
    v_new_wh      orders.ship_warehouse_id%TYPE;
    v_checked     PLS_INTEGER := 0;
    v_passed      PLS_INTEGER := 0;
    v_fixed       PLS_INTEGER := 0;
    v_warned      PLS_INTEGER := 0;
    v_failed      PLS_INTEGER := 0;
    v_on_hold     PLS_INTEGER := 0;
    v_window_cnt  PLS_INTEGER := 0;
    v_fail_pct    NUMBER;

    CURSOR c_orders (cp_from DATE, cp_to DATE) IS
        SELECT o.order_id,
               o.order_status,
               o.order_total,
               o.tax_amount,
               o.shipping_fee,
               o.ship_warehouse_id,
               c.region                    AS customer_region,
               c.is_active                 AS customer_active,
               NVL(it.item_count, 0)       AS item_count,
               NVL(it.items_total, 0)      AS items_total,
               NVL(pm.captured_count, 0)   AS captured_count,
               NVL(pm.captured_amount, 0)  AS captured_amount
        FROM orders o
        JOIN customers c
          ON c.customer_id = o.customer_id
        LEFT JOIN (SELECT order_id, COUNT(*) AS item_count, SUM(line_total) AS items_total
                   FROM order_items
                   GROUP BY order_id) it
          ON it.order_id = o.order_id
        LEFT JOIN (SELECT order_id, COUNT(*) AS captured_count, SUM(amount) AS captured_amount
                   FROM payments
                   WHERE payment_status = 'CAPTURED'
                   GROUP BY order_id) pm
          ON pm.order_id = o.order_id
        WHERE o.order_date >= cp_from
          AND o.order_date <  cp_to
          AND o.dq_status IN ('UNCHECKED', 'WARNING', 'FAILED')
        ORDER BY o.order_id;

    PROCEDURE add_msg (p_msg IN VARCHAR2) IS
    BEGIN
        v_dq_message := SUBSTR(v_dq_message || CASE WHEN v_dq_message IS NOT NULL THEN '; ' END || p_msg, 1, 400);
    END add_msg;
BEGIN
    IF p_run_date IS NULL OR p_lookback_days IS NULL OR p_lookback_days NOT BETWEEN 1 AND 1000 THEN
        RAISE_APPLICATION_ERROR(-20101, 'Invalid parameters: p_run_date=' || TO_CHAR(p_run_date, 'YYYY-MM-DD')
                                        || ', p_lookback_days=' || p_lookback_days);
    END IF;

    v_from_date := TRUNC(p_run_date) - p_lookback_days + 1;
    v_to_date   := TRUNC(p_run_date) + 1;
    sp_log_etl_run(v_run_id, c_proc, 'START', 'STARTED', NULL,
                   'Window ' || TO_CHAR(v_from_date, 'YYYY-MM-DD') || ' to ' || TO_CHAR(p_run_date, 'YYYY-MM-DD'));

    -- Default warehouse per region = largest warehouse in that region
    FOR r IN (SELECT region, warehouse_id
              FROM (SELECT region, warehouse_id,
                           ROW_NUMBER() OVER (PARTITION BY region
                                              ORDER BY capacity_units DESC NULLS LAST, warehouse_id) AS rn
                    FROM warehouses)
              WHERE rn = 1)
    LOOP
        v_default_wh(r.region) := r.warehouse_id;
    END LOOP;

    FOR r IN c_orders(v_from_date, v_to_date) LOOP
        v_checked    := v_checked + 1;
        v_dq_status  := 'PASSED';
        v_dq_message := NULL;
        v_new_status := r.order_status;
        v_new_wh     := r.ship_warehouse_id;

        BEGIN
            -- R1: every order must have at least one line item
            IF r.item_count = 0 THEN
                RAISE e_no_items;
            END IF;

            -- R2: header total must equal lines + tax + shipping
            IF ABS(r.items_total + r.tax_amount + r.shipping_fee - r.order_total) > 0.01 THEN
                RAISE e_total_mismatch;
            END IF;

            -- R3/R4: payments (not applicable to pending or cancelled orders)
            IF r.order_status NOT IN ('PENDING', 'CANCELLED') THEN
                IF r.captured_count = 0 THEN
                    v_dq_status := 'WARNING';
                    add_msg('NO_CAPTURED_PAYMENT');
                ELSIF ABS(r.captured_amount - r.order_total) > 0.01 THEN
                    RAISE e_payment_mismatch;
                END IF;
            END IF;

            -- R5: missing ship warehouse -> auto-fix with the regional default
            IF r.ship_warehouse_id IS NULL AND r.order_status <> 'CANCELLED' THEN
                IF v_default_wh.EXISTS(r.customer_region) THEN
                    v_new_wh := v_default_wh(r.customer_region);
                    add_msg('AUTOFIX_WAREHOUSE=' || v_new_wh);
                    IF v_dq_status = 'PASSED' THEN
                        v_dq_status := 'FIXED';
                    END IF;
                ELSE
                    v_dq_status := 'WARNING';
                    add_msg('NO_WAREHOUSE_FOR_REGION=' || r.customer_region);
                END IF;
            END IF;

            -- R6: order placed by a deactivated customer account
            IF r.customer_active = 'N' THEN
                v_dq_status := 'WARNING';
                add_msg('INACTIVE_CUSTOMER');
            END IF;
        EXCEPTION
            WHEN e_no_items THEN
                v_dq_status := 'FAILED';
                add_msg('NO_LINE_ITEMS');
            WHEN e_total_mismatch THEN
                v_dq_status := 'FAILED';
                add_msg('TOTAL_MISMATCH header=' || TO_CHAR(r.order_total, 'FM9999999990.00')
                        || ' computed=' || TO_CHAR(r.items_total + r.tax_amount + r.shipping_fee, 'FM9999999990.00'));
            WHEN e_payment_mismatch THEN
                v_dq_status := 'FAILED';
                add_msg('PAYMENT_MISMATCH captured=' || TO_CHAR(r.captured_amount, 'FM9999999990.00')
                        || ' total=' || TO_CHAR(r.order_total, 'FM9999999990.00'));
        END;

        IF v_dq_status = 'FAILED' AND r.order_status IN ('PENDING', 'PAID') THEN
            v_new_status := 'ON_HOLD';
            v_on_hold    := v_on_hold + 1;
        END IF;

        UPDATE orders
        SET dq_status         = v_dq_status,
            dq_message        = v_dq_message,
            dq_checked_at     = SYSTIMESTAMP,
            order_status      = v_new_status,
            ship_warehouse_id = v_new_wh,
            updated_at        = CASE
                                    WHEN v_new_status <> order_status
                                      OR NVL(v_new_wh, -1) <> NVL(ship_warehouse_id, -1)
                                    THEN SYSTIMESTAMP
                                    ELSE updated_at
                                END
        WHERE order_id = r.order_id;

        CASE v_dq_status
            WHEN 'PASSED'  THEN v_passed := v_passed + 1;
            WHEN 'FIXED'   THEN v_fixed  := v_fixed + 1;
            WHEN 'WARNING' THEN v_warned := v_warned + 1;
            ELSE                v_failed := v_failed + 1;
        END CASE;

        IF MOD(v_checked, p_commit_every) = 0 THEN
            COMMIT;
        END IF;
    END LOOP;
    COMMIT;

    -- Rate is measured against every order in the window, not just the ones re-checked
    -- this run (a re-run only re-checks previously flagged orders)
    SELECT COUNT(*)
    INTO v_window_cnt
    FROM orders
    WHERE order_date >= v_from_date
      AND order_date <  v_to_date;

    v_fail_pct := CASE WHEN v_window_cnt > 0 THEN ROUND(v_failed * 100 / v_window_cnt, 2) ELSE 0 END;
    sp_log_etl_run(v_run_id, c_proc, 'VALIDATE', 'INFO', v_checked,
                   'window_orders=' || v_window_cnt || ' checked=' || v_checked
                   || ' passed=' || v_passed || ' fixed=' || v_fixed || ' warning=' || v_warned
                   || ' failed=' || v_failed || ' on_hold=' || v_on_hold || ' fail_pct=' || v_fail_pct);

    -- Flags are already committed so analysts can inspect them; the batch still stops here
    IF v_fail_pct > p_max_fail_pct THEN
        RAISE_APPLICATION_ERROR(-20199, 'Failure rate ' || v_fail_pct || '% exceeds threshold ' || p_max_fail_pct || '%');
    END IF;

    sp_log_etl_run(v_run_id, c_proc, 'END', 'SUCCESS', v_checked, 'Validation complete');
EXCEPTION
    WHEN e_fail_threshold THEN
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', v_checked, SQLERRM, SQLCODE);
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', v_checked,
                       SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SQLCODE);
        RAISE;
END sp_validate_orders;
/
