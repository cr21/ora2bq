CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.product_categories` (
  category_id        INT64  NOT NULL,
  category_name      STRING NOT NULL,
  parent_category_id INT64,
  category_level     INT64  NOT NULL,
  is_active          STRING DEFAULT 'Y' NOT NULL
);
-- NOTE: PK_PRODUCT_CATEGORIES PRIMARY KEY (category_id) not enforced
-- NOTE: FK_CATEGORY_PARENT FOREIGN KEY (parent_category_id) REFERENCES product_categories (category_id)
-- NOTE: CK_CATEGORY_LEVEL CHECK (category_level IN (1,2,3)); CK_CATEGORY_ACTIVE CHECK (is_active IN ('Y','N'))
