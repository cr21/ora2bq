CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.products` (
  product_id      INT64         NOT NULL,  -- NOTE: Oracle identity column (ISEQ$$_73505)
  sku             STRING        NOT NULL,
  product_name    STRING        NOT NULL,
  category_id     INT64         NOT NULL,
  supplier_id     INT64         NOT NULL,
  unit_cost       NUMERIC(10,2) NOT NULL,
  list_price      NUMERIC(10,2) NOT NULL,
  weight_kg       NUMERIC(7,3),
  launch_date     DATE          NOT NULL,
  is_discontinued STRING        DEFAULT 'N' NOT NULL
);
-- NOTE: PK_PRODUCTS PRIMARY KEY (product_id); UQ_PRODUCTS_SKU UNIQUE (sku) not enforced
-- NOTE: FK_PRODUCTS_CATEGORY -> product_categories (category_id); FK_PRODUCTS_SUPPLIER -> suppliers (supplier_id)
-- NOTE: CK_PRODUCTS_PRICE CHECK (unit_cost > 0 AND list_price >= unit_cost); CK_PRODUCTS_DISC CHECK (is_discontinued IN ('Y','N'))
-- NOTE: indexes IX_PRODUCTS_CATEGORY, IX_PRODUCTS_SUPPLIER dropped
