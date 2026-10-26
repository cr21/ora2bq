CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.order_items` (
  order_item_id INT64         NOT NULL,  -- NOTE: Oracle identity column (ISEQ$$_73525)
  order_id      INT64         NOT NULL,
  line_number   INT64         NOT NULL,
  product_id    INT64         NOT NULL,
  quantity      INT64         NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL,
  discount_pct  NUMERIC(5,2)  DEFAULT 0 NOT NULL,
  line_total    NUMERIC(12,2) NOT NULL
)
CLUSTER BY order_id;
-- NOTE: PK_ORDER_ITEMS PRIMARY KEY (order_item_id); UQ_ORDER_ITEMS_LINE UNIQUE (order_id, line_number) not enforced
-- NOTE: FK_ORDER_ITEMS_ORDER -> orders (order_id); FK_ORDER_ITEMS_PRODUCT -> products (product_id)
-- NOTE: CK_ORDER_ITEMS_QTY CHECK (quantity > 0); CK_ORDER_ITEMS_DISC CHECK (discount_pct BETWEEN 0 AND 100)
-- NOTE: index IX_ORDER_ITEMS_PRODUCT dropped
