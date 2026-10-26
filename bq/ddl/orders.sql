CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.orders` (
  order_id          INT64         NOT NULL,  -- NOTE: Oracle identity column (ISEQ$$_73518)
  customer_id       INT64         NOT NULL,
  order_date        DATETIME      NOT NULL,  -- NOTE: Oracle DATE holds time-of-day (procedures TRUNC it), mapped to DATETIME
  order_status      STRING        NOT NULL,
  channel           STRING        NOT NULL,
  ship_warehouse_id INT64,
  discount_amount   NUMERIC(12,2) DEFAULT 0 NOT NULL,
  tax_amount        NUMERIC(12,2) DEFAULT 0 NOT NULL,
  shipping_fee      NUMERIC(8,2)  DEFAULT 0 NOT NULL,
  order_total       NUMERIC(12,2) NOT NULL,
  currency_code     STRING        DEFAULT 'USD' NOT NULL,
  dq_status         STRING        DEFAULT 'UNCHECKED' NOT NULL,
  dq_message        STRING,
  dq_checked_at     TIMESTAMP,
  created_at        TIMESTAMP     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  updated_at        TIMESTAMP
)
PARTITION BY DATE(order_date)
CLUSTER BY order_status, dq_status;
-- NOTE: PK_ORDERS PRIMARY KEY (order_id) not enforced
-- NOTE: FK_ORDERS_CUSTOMER -> customers (customer_id); FK_ORDERS_WAREHOUSE -> warehouses (warehouse_id)
-- NOTE: CK_ORDERS_STATUS CHECK (order_status IN ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED','RETURNED','ON_HOLD'))
-- NOTE: CK_ORDERS_CHANNEL CHECK (channel IN ('WEB','MOBILE','STORE','PHONE'))
-- NOTE: CK_ORDERS_DQ CHECK (dq_status IN ('UNCHECKED','PASSED','FIXED','WARNING','FAILED'))
-- NOTE: indexes IX_ORDERS_DATE, IX_ORDERS_WAREHOUSE, IX_ORDERS_STATUS, IX_ORDERS_CUSTOMER dropped
