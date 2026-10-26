CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.daily_sales_summary` (
  summary_date      DATE          NOT NULL,
  region            STRING        NOT NULL,
  top_category_id   INT64         NOT NULL,
  top_category_name STRING        NOT NULL,
  channel           STRING        NOT NULL,
  order_count       INT64         DEFAULT 0 NOT NULL,
  units_sold        INT64         DEFAULT 0 NOT NULL,
  gross_sales       NUMERIC(14,2) DEFAULT 0 NOT NULL,
  discount_total    NUMERIC(14,2) DEFAULT 0 NOT NULL,
  net_sales         NUMERIC(14,2) DEFAULT 0 NOT NULL,
  cogs              NUMERIC(14,2) DEFAULT 0 NOT NULL,
  gross_margin      NUMERIC(14,2) DEFAULT 0 NOT NULL,
  margin_pct        NUMERIC(7,2),
  avg_order_value   NUMERIC(12,2),
  return_units      INT64         DEFAULT 0 NOT NULL,
  refund_total      NUMERIC(14,2) DEFAULT 0 NOT NULL,
  mtd_net_sales     NUMERIC(16,2),
  load_ts           TIMESTAMP     NOT NULL
)
PARTITION BY summary_date
CLUSTER BY region, top_category_id, channel;
-- NOTE: PK_DAILY_SALES_SUMMARY PRIMARY KEY (summary_date, region, top_category_id, channel) not enforced
