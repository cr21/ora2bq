CREATE TABLE IF NOT EXISTS `project-5c016d48-80d5-4534-b69.orc_dataset.customers` (
  customer_id  INT64     NOT NULL,  -- NOTE: Oracle identity column (ISEQ$$_73496)
  first_name   STRING    NOT NULL,
  last_name    STRING    NOT NULL,
  email        STRING    NOT NULL,
  phone        STRING,
  city         STRING,
  state_code   STRING,
  region       STRING    NOT NULL,
  signup_date  DATE      NOT NULL,
  loyalty_tier STRING    DEFAULT 'BRONZE' NOT NULL,
  is_active    STRING    DEFAULT 'Y' NOT NULL,
  created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  updated_at   TIMESTAMP
);
-- NOTE: PK_CUSTOMERS PRIMARY KEY (customer_id); UQ_CUSTOMERS_EMAIL UNIQUE (email) not enforced
-- NOTE: CK_CUSTOMERS_REGION CHECK (region IN ('NORTHEAST','SOUTHEAST','MIDWEST','SOUTHWEST','WEST'))
-- NOTE: CK_CUSTOMERS_TIER CHECK (loyalty_tier IN ('BRONZE','SILVER','GOLD','PLATINUM')); CK_CUSTOMERS_ACTIVE CHECK (is_active IN ('Y','N'))
