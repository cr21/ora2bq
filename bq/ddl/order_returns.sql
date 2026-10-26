CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.order_returns` (
  return_id      INT64         NOT NULL,  -- NOTE: Oracle identity column (ISEQ$$_73539)
  order_id       INT64         NOT NULL,
  order_item_id  INT64         NOT NULL,
  product_id     INT64         NOT NULL,
  return_date    DATE          NOT NULL,
  quantity       INT64         NOT NULL,
  return_reason  STRING        NOT NULL,
  item_condition STRING        NOT NULL,
  return_status  STRING        NOT NULL,
  refund_amount  NUMERIC(12,2),
  restocked_qty  INT64,
  processed_at   TIMESTAMP,
  reject_reason  STRING
)
CLUSTER BY return_status, order_id;
-- NOTE: PK_ORDER_RETURNS PRIMARY KEY (return_id) not enforced
-- NOTE: FK_ORDER_RETURNS_ORDER -> orders; FK_ORDER_RETURNS_ITEM -> order_items; FK_ORDER_RETURNS_PRODUCT -> products
-- NOTE: CK_ORDER_RETURNS_QTY CHECK (quantity > 0)
-- NOTE: CK_ORDER_RETURNS_REASON CHECK (return_reason IN ('DAMAGED','WRONG_ITEM','NOT_AS_DESCRIBED','CHANGED_MIND','LATE_DELIVERY'))
-- NOTE: CK_ORDER_RETURNS_COND CHECK (item_condition IN ('NEW','OPENED','DAMAGED'))
-- NOTE: CK_ORDER_RETURNS_STATUS CHECK (return_status IN ('REQUESTED','RECEIVED','PROCESSED','REJECTED'))
-- NOTE: indexes IX_ORDER_RETURNS_ORDER, IX_ORDER_RETURNS_STATUS dropped
