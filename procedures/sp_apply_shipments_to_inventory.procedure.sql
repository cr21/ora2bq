CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_APPLY_SHIPMENTS_TO_INVENTORY" (
    p_run_date    IN DATE        DEFAULT TRUNC(SYSDATE) - 1,
    p_batch_size  IN PLS_INTEGER DEFAULT 500
)
AS
    c_proc CONSTANT VARCHAR2(40) := 'SP_APPLY_SHIPMENTS_TO_INVENTORY';
    c_check_violation CONSTANT PLS_INTEGER := 2290;   -- ORA-02290 check constraint violated

    e_bulk_errors EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_bulk_errors, -24381);

    CURSOR c_pending (cp_cutoff DATE) IS
        SELECT s.shipment_id
        FROM shipments s
        JOIN orders o
          ON o.order_id = s.order_id
        WHERE s.inventory_applied = 'N'
          AND s.ship_date < cp_cutoff
          AND o.dq_status <> 'FAILED'
        ORDER BY s.ship_date, s.shipment_id;

    v_run_id          NUMBER := etl_run_seq.NEXTVAL;
    v_ship_ids        SYS.ODCINUMBERLIST;
    v_prod_ids        SYS.ODCINUMBERLIST;
    v_wh_ids          SYS.ODCINUMBERLIST;
    v_qtys            SYS.ODCINUMBERLIST;
    v_err_idx         SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
    v_batch_no        PLS_INTEGER := 0;
    v_shipments_done  PLS_INTEGER := 0;
    v_rows_updated    PLS_INTEGER := 0;
    v_rows_created    PLS_INTEGER := 0;
    v_stockouts       PLS_INTEGER := 0;
    v_reserved_rows   PLS_INTEGER := 0;
    v_idx             PLS_INTEGER;
    v_on_hand         inventory.qty_on_hand%TYPE;
BEGIN
    IF p_batch_size IS NULL OR p_batch_size NOT BETWEEN 1 AND 10000 THEN
        RAISE_APPLICATION_ERROR(-20201, 'p_batch_size must be between 1 and 10000, got ' || p_batch_size);
    END IF;
    sp_log_etl_run(v_run_id, c_proc, 'START', 'STARTED', NULL,
                   'Applying shipments shipped on or before ' || TO_CHAR(p_run_date, 'YYYY-MM-DD'));

    OPEN c_pending(TRUNC(p_run_date) + 1);
    LOOP
        FETCH c_pending BULK COLLECT INTO v_ship_ids LIMIT p_batch_size;
        EXIT WHEN v_ship_ids.COUNT = 0;
        v_batch_no := v_batch_no + 1;

        -- Units shipped per product/warehouse in this batch
        SELECT oi.product_id, s.warehouse_id, SUM(oi.quantity)
        BULK COLLECT INTO v_prod_ids, v_wh_ids, v_qtys
        FROM shipments s
        JOIN order_items oi
          ON oi.order_id = s.order_id
        WHERE s.shipment_id IN (SELECT COLUMN_VALUE FROM TABLE(v_ship_ids))
        GROUP BY oi.product_id, s.warehouse_id;

        -- Make sure an inventory row exists for every product/warehouse touched
        FORALL i IN 1 .. v_prod_ids.COUNT
            INSERT INTO inventory (product_id, warehouse_id, qty_on_hand, qty_reserved, safety_stock, reorder_point, last_updated)
            SELECT v_prod_ids(i), v_wh_ids(i), 0, 0, 0, 0, SYSTIMESTAMP
            FROM dual
            WHERE NOT EXISTS (SELECT 1
                              FROM inventory
                              WHERE product_id = v_prod_ids(i)
                                AND warehouse_id = v_wh_ids(i));
        v_rows_created := v_rows_created + SQL%ROWCOUNT;

        BEGIN
            FORALL i IN 1 .. v_prod_ids.COUNT SAVE EXCEPTIONS
                UPDATE inventory
                SET qty_on_hand  = qty_on_hand - v_qtys(i),
                    last_updated = SYSTIMESTAMP
                WHERE product_id   = v_prod_ids(i)
                  AND warehouse_id = v_wh_ids(i);
            v_rows_updated := v_rows_updated + SQL%ROWCOUNT;
        EXCEPTION
            WHEN e_bulk_errors THEN
                v_rows_updated := v_rows_updated + SQL%ROWCOUNT;
                -- Copy the failed indexes before running any other SQL
                v_err_idx.DELETE;
                FOR j IN 1 .. SQL%BULK_EXCEPTIONS.COUNT LOOP
                    IF SQL%BULK_EXCEPTIONS(j).ERROR_CODE <> c_check_violation THEN
                        RAISE_APPLICATION_ERROR(-20202, 'Unexpected error ORA-' || SQL%BULK_EXCEPTIONS(j).ERROR_CODE
                                                        || ' updating inventory in batch ' || v_batch_no);
                    END IF;
                    v_err_idx.EXTEND;
                    v_err_idx(v_err_idx.COUNT) := SQL%BULK_EXCEPTIONS(j).ERROR_INDEX;
                END LOOP;

                -- Stock-out: ship what we have, clamp to zero, record the shortfall
                FOR j IN 1 .. v_err_idx.COUNT LOOP
                    v_idx := v_err_idx(j);
                    SELECT qty_on_hand
                    INTO v_on_hand
                    FROM inventory
                    WHERE product_id = v_prod_ids(v_idx)
                      AND warehouse_id = v_wh_ids(v_idx)
                    FOR UPDATE;

                    UPDATE inventory
                    SET qty_on_hand  = 0,
                        last_updated = SYSTIMESTAMP
                    WHERE product_id = v_prod_ids(v_idx)
                      AND warehouse_id = v_wh_ids(v_idx);

                    v_stockouts := v_stockouts + 1;
                    sp_log_etl_run(v_run_id, c_proc, 'STOCKOUT', 'WARNING', v_qtys(v_idx),
                                   'product_id=' || v_prod_ids(v_idx) || ' warehouse_id=' || v_wh_ids(v_idx)
                                   || ' on_hand=' || v_on_hand || ' shipped=' || v_qtys(v_idx)
                                   || ' shortfall=' || (v_qtys(v_idx) - v_on_hand));
                END LOOP;
        END;

        FORALL i IN 1 .. v_ship_ids.COUNT
            UPDATE shipments
            SET inventory_applied = 'Y',
                applied_at        = SYSTIMESTAMP
            WHERE shipment_id = v_ship_ids(i);
        v_shipments_done := v_shipments_done + SQL%ROWCOUNT;

        COMMIT;
        sp_log_etl_run(v_run_id, c_proc, 'BATCH_' || v_batch_no, 'INFO', v_ship_ids.COUNT,
                       'shipments=' || v_ship_ids.COUNT || ' product_warehouse_rows=' || v_prod_ids.COUNT);
    END LOOP;
    CLOSE c_pending;

    -- Rebuild reservations for orders that are paid but not yet shipped
    UPDATE inventory
    SET qty_reserved = 0,
        last_updated = SYSTIMESTAMP
    WHERE qty_reserved <> 0;

    MERGE INTO inventory inv
    USING (
        SELECT oi.product_id,
               o.ship_warehouse_id AS warehouse_id,
               SUM(oi.quantity)    AS reserved_qty
        FROM orders o
        JOIN order_items oi
          ON oi.order_id = o.order_id
        WHERE o.order_status IN ('PENDING', 'PAID', 'ON_HOLD')
          AND o.channel <> 'STORE'
          AND o.ship_warehouse_id IS NOT NULL
        GROUP BY oi.product_id, o.ship_warehouse_id
    ) src
    ON (inv.product_id = src.product_id AND inv.warehouse_id = src.warehouse_id)
    WHEN MATCHED THEN
        UPDATE SET inv.qty_reserved = src.reserved_qty,
                   inv.last_updated = SYSTIMESTAMP
    WHEN NOT MATCHED THEN
        INSERT (product_id, warehouse_id, qty_on_hand, qty_reserved, safety_stock, reorder_point, last_updated)
        VALUES (src.product_id, src.warehouse_id, 0, src.reserved_qty, 0, 0, SYSTIMESTAMP);
    v_reserved_rows := SQL%ROWCOUNT;
    COMMIT;

    sp_log_etl_run(v_run_id, c_proc, 'END', 'SUCCESS', v_shipments_done,
                   'batches=' || v_batch_no || ' shipments=' || v_shipments_done
                   || ' inventory_rows_updated=' || v_rows_updated || ' inventory_rows_created=' || v_rows_created
                   || ' stockouts=' || v_stockouts || ' reserved_rows=' || v_reserved_rows);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        IF c_pending%ISOPEN THEN
            CLOSE c_pending;
        END IF;
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', v_shipments_done,
                       SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SQLCODE);
        RAISE;
END sp_apply_shipments_to_inventory;
/
