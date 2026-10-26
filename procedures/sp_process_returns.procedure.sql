CREATE OR REPLACE EDITIONABLE PROCEDURE "RETAIL"."SP_PROCESS_RETURNS" (
    p_run_date            IN DATE   DEFAULT TRUNC(SYSDATE) - 1,
    p_return_window_days  IN NUMBER DEFAULT 30,
    p_request_expiry_days IN NUMBER DEFAULT 21
)
AS
    c_proc CONSTANT VARCHAR2(30) := 'SP_PROCESS_RETURNS';

    v_run_id           NUMBER    := etl_run_seq.NEXTVAL;
    v_run_ts           TIMESTAMP := SYSTIMESTAMP;
    v_cutoff           DATE;
    v_rejected_window  PLS_INTEGER := 0;
    v_rejected_expired PLS_INTEGER := 0;
    v_processed        PLS_INTEGER := 0;
    v_restock_rows     PLS_INTEGER := 0;
    v_refund_rows      PLS_INTEGER := 0;
    v_returned_orders  PLS_INTEGER := 0;
    v_refund_total     NUMBER := 0;
    v_units_restocked  NUMBER := 0;
BEGIN
    IF p_run_date IS NULL OR NVL(p_return_window_days, 0) <= 0 OR NVL(p_request_expiry_days, 0) <= 0 THEN
        RAISE_APPLICATION_ERROR(-20301, 'Invalid parameters for ' || c_proc);
    END IF;
    v_cutoff := TRUNC(p_run_date) + 1;
    sp_log_etl_run(v_run_id, c_proc, 'START', 'STARTED', NULL,
                   'Processing returns received before ' || TO_CHAR(v_cutoff, 'YYYY-MM-DD'));

    -- Step 1: reject returns received after the window (measured from delivery; store orders from order date)
    UPDATE order_returns r
    SET r.return_status = 'REJECTED',
        r.refund_amount = 0,
        r.restocked_qty = 0,
        r.processed_at  = v_run_ts,
        r.reject_reason = 'Return window of ' || p_return_window_days || ' days exceeded'
    WHERE r.return_status = 'RECEIVED'
      AND r.return_date < v_cutoff
      AND r.return_date > (SELECT NVL(MAX(s.delivered_date), MAX(TRUNC(o.order_date)))
                           FROM orders o
                           LEFT JOIN shipments s
                             ON s.order_id = o.order_id
                           WHERE o.order_id = r.order_id) + p_return_window_days;
    v_rejected_window := SQL%ROWCOUNT;

    -- Step 2: requests where the customer never sent the item back
    UPDATE order_returns r
    SET r.return_status = 'REJECTED',
        r.refund_amount = 0,
        r.restocked_qty = 0,
        r.processed_at  = v_run_ts,
        r.reject_reason = 'Item not received within ' || p_request_expiry_days || ' days of request'
    WHERE r.return_status = 'REQUESTED'
      AND r.return_date < TRUNC(p_run_date) - p_request_expiry_days;
    v_rejected_expired := SQL%ROWCOUNT;

    -- Step 3: refund and restock amounts
    MERGE INTO order_returns tgt
    USING (
        SELECT r.return_id,
               ROUND(r.quantity * (oi.line_total / oi.quantity)
                     * DECODE(r.item_condition,
                              'NEW',     1,
                              'OPENED',  DECODE(r.return_reason, 'DAMAGED', 1, 'WRONG_ITEM', 1, 'NOT_AS_DESCRIBED', 1, 0.9),
                              'DAMAGED', DECODE(r.return_reason, 'DAMAGED', 1, 'WRONG_ITEM', 1, 0.5),
                              0), 2)                          AS refund_amount,
               DECODE(r.item_condition, 'DAMAGED', 0, r.quantity) AS restocked_qty
        FROM order_returns r
        JOIN order_items oi
          ON oi.order_item_id = r.order_item_id
        WHERE r.return_status = 'RECEIVED'
          AND r.return_date < v_cutoff
    ) src
    ON (tgt.return_id = src.return_id)
    WHEN MATCHED THEN
        UPDATE SET tgt.refund_amount = src.refund_amount,
                   tgt.restocked_qty = src.restocked_qty,
                   tgt.return_status = 'PROCESSED',
                   tgt.processed_at  = v_run_ts;
    v_processed := SQL%ROWCOUNT;

    -- Step 4: put sellable units back into the warehouse that shipped them
    MERGE INTO inventory inv
    USING (
        SELECT r.product_id,
               COALESCE(s.warehouse_id, o.ship_warehouse_id) AS warehouse_id,
               SUM(r.restocked_qty)                          AS qty
        FROM order_returns r
        JOIN orders o
          ON o.order_id = r.order_id
        LEFT JOIN shipments s
          ON s.order_id = r.order_id
        WHERE r.processed_at = v_run_ts
          AND r.return_status = 'PROCESSED'
          AND NVL(r.restocked_qty, 0) > 0
          AND COALESCE(s.warehouse_id, o.ship_warehouse_id) IS NOT NULL
        GROUP BY r.product_id, COALESCE(s.warehouse_id, o.ship_warehouse_id)
    ) src
    ON (inv.product_id = src.product_id AND inv.warehouse_id = src.warehouse_id)
    WHEN MATCHED THEN
        UPDATE SET inv.qty_on_hand  = inv.qty_on_hand + src.qty,
                   inv.last_updated = SYSTIMESTAMP
    WHEN NOT MATCHED THEN
        INSERT (product_id, warehouse_id, qty_on_hand, qty_reserved, safety_stock, reorder_point, last_updated)
        VALUES (src.product_id, src.warehouse_id, src.qty, 0, 0, 0, SYSTIMESTAMP);
    v_restock_rows := SQL%ROWCOUNT;

    -- Step 5: refund to the method used for the original (first) captured payment
    INSERT INTO payments (order_id, payment_date, payment_method, amount, payment_status, transaction_ref)
    SELECT r.order_id,
           TRUNC(p_run_date),
           NVL((SELECT MAX(p.payment_method) KEEP (DENSE_RANK FIRST ORDER BY p.payment_date, p.payment_id)
                FROM payments p
                WHERE p.order_id = r.order_id
                  AND p.payment_status = 'CAPTURED'), 'CREDIT_CARD'),
           r.refund_amount,
           'REFUNDED',
           'RFND-' || r.return_id
    FROM order_returns r
    WHERE r.processed_at = v_run_ts
      AND r.return_status = 'PROCESSED'
      AND r.refund_amount > 0;
    v_refund_rows := SQL%ROWCOUNT;

    -- Step 6: orders where every unit has now been returned
    UPDATE orders o
    SET o.order_status = 'RETURNED',
        o.updated_at   = SYSTIMESTAMP
    WHERE o.order_status = 'DELIVERED'
      AND o.order_id IN (SELECT r.order_id FROM order_returns r WHERE r.processed_at = v_run_ts)
      AND (SELECT SUM(oi.quantity) FROM order_items oi WHERE oi.order_id = o.order_id)
          <= (SELECT SUM(r.quantity)
              FROM order_returns r
              WHERE r.order_id = o.order_id
                AND r.return_status = 'PROCESSED');
    v_returned_orders := SQL%ROWCOUNT;

    SELECT NVL(SUM(refund_amount), 0), NVL(SUM(restocked_qty), 0)
    INTO v_refund_total, v_units_restocked
    FROM order_returns
    WHERE processed_at = v_run_ts
      AND return_status = 'PROCESSED';

    COMMIT;

    sp_log_etl_run(v_run_id, c_proc, 'END', 'SUCCESS', v_processed,
                   'processed=' || v_processed || ' rejected_window=' || v_rejected_window
                   || ' rejected_expired=' || v_rejected_expired || ' refunds=' || v_refund_rows
                   || ' refund_total=' || TO_CHAR(v_refund_total, 'FM9999999990.00')
                   || ' units_restocked=' || v_units_restocked || ' inventory_rows=' || v_restock_rows
                   || ' orders_returned=' || v_returned_orders);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        sp_log_etl_run(v_run_id, c_proc, 'END', 'FAILED', NULL,
                       SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, SQLCODE);
        RAISE;
END sp_process_returns;
/
