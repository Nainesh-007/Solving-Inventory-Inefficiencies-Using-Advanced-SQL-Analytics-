-- 1. CREATE STAGING TABLE

DROP TABLE IF EXISTS stg_inventory;

CREATE TABLE stg_inventory (
    sale_date          DATE,
    store_id           VARCHAR(10),
    product_id         VARCHAR(10),
    category           VARCHAR(50),
    region             VARCHAR(20),
    inventory_level    INTEGER,
    units_sold         INTEGER,
    units_ordered      INTEGER,
    demand_forecast    NUMERIC(10,2),
    price              NUMERIC(10,2),
    discount           INTEGER,
    weather_condition  VARCHAR(20),
    holiday_promotion  INTEGER,
    competitor_pricing NUMERIC(10,2),
    seasonality        VARCHAR(20)
);


-- 2. LOAD THE CSV INTO THE STAGING TABLE

COPY stg_inventory
FROM 'D:/Projects/Solving inventory inefficiencies (SQL)/inventory_forecasting.csv'
WITH (FORMAT csv, HEADER true);

SELECT COUNT(*) FROM stg_inventory;


-- 3. CREATE THE FINAL TABLES

CREATE TABLE stores (
    store_id   VARCHAR(10) PRIMARY KEY
);

CREATE TABLE products (
    product_id VARCHAR(10) PRIMARY KEY,
    category   VARCHAR(50) NOT NULL
);

CREATE TABLE inventory_records (
    record_date        DATE          NOT NULL,
    store_id           VARCHAR(10)   NOT NULL REFERENCES stores(store_id),
    product_id         VARCHAR(10)   NOT NULL REFERENCES products(product_id),
    region             VARCHAR(20)   NOT NULL,
    inventory_level    INTEGER       NOT NULL CHECK (inventory_level >= 0),
    units_sold         INTEGER       NOT NULL CHECK (units_sold >= 0),
    units_ordered      INTEGER       NOT NULL CHECK (units_ordered >= 0),
    demand_forecast    NUMERIC(10,2) NOT NULL CHECK (demand_forecast >= 0),
    price              NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    discount_pct       SMALLINT      NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
    weather_condition  VARCHAR(20),
    holiday_promotion  BOOLEAN       NOT NULL DEFAULT FALSE,
    competitor_price   NUMERIC(10,2),
    season             VARCHAR(20),
    PRIMARY KEY (record_date, store_id, product_id)
);



-- 4. FILL THE FINAL TABLES FROM STAGING

INSERT INTO stores  SELECT DISTINCT store_id FROM stg_inventory;
INSERT INTO products SELECT DISTINCT product_id, category FROM stg_inventory;

INSERT INTO inventory_records
SELECT sale_date, store_id, product_id, region, inventory_level, units_sold, units_ordered,
       demand_forecast, price, discount, weather_condition,
       (holiday_promotion = 1), competitor_pricing, seasonality
FROM stg_inventory;

SELECT COUNT(*) AS rows_loaded, MIN(record_date) AS first_day, MAX(record_date) AS last_day
FROM inventory_records;

DROP TABLE stg_inventory;



-- 5. CREATE INDEXES

CREATE INDEX idx_inv_series       ON inventory_records (store_id, product_id, record_date);
CREATE INDEX idx_inv_product_date ON inventory_records (product_id, record_date);
ANALYZE inventory_records;



-- 6. CREATE THE SETTINGS TABLE

CREATE TABLE replenishment_params (
    lead_time_days NUMERIC NOT NULL,
    review_days    NUMERIC NOT NULL,
    service_z      NUMERIC NOT NULL
);

INSERT INTO replenishment_params VALUES (1, 1, 1.65);



-- 7. VIEW 1: DEMAND STATISTICS

CREATE VIEW v_demand_stats AS
WITH ranked AS (
    SELECT store_id, product_id, record_date, units_sold, inventory_level,
           DENSE_RANK() OVER (ORDER BY record_date DESC) AS day_rank
    FROM inventory_records
)
SELECT r.store_id,
       r.product_id,
       p.category,
       MAX(CASE WHEN r.day_rank = 1 THEN r.inventory_level END)  AS inventory_level,
       AVG(CASE WHEN r.day_rank <= 28 THEN r.units_sold END)     AS avg_daily_demand,
       COALESCE(STDDEV_SAMP(r.units_sold), 0)                    AS sd_daily_demand
FROM ranked r
JOIN products p ON p.product_id = r.product_id
WHERE r.day_rank <= 90
GROUP BY r.store_id, r.product_id, p.category;



-- 8. VIEW 2: REPLENISHMENT DECISIONS

CREATE VIEW v_replenishment AS
WITH calc AS (
    SELECT s.store_id, s.product_id, s.category, s.inventory_level,
           s.avg_daily_demand, s.sd_daily_demand, p.lead_time_days,
           s.inventory_level / NULLIF(s.avg_daily_demand, 0) AS cover_days,
           s.avg_daily_demand * p.lead_time_days
             + p.service_z * s.sd_daily_demand * SQRT(p.lead_time_days)                  AS reorder_point,
           s.avg_daily_demand * (p.lead_time_days + p.review_days)
             + p.service_z * s.sd_daily_demand * SQRT(p.lead_time_days + p.review_days)  AS order_up_to_level
    FROM v_demand_stats s
    CROSS JOIN replenishment_params p
)
SELECT calc.*,
       CASE WHEN inventory_level < avg_daily_demand * lead_time_days THEN 'CRITICAL'
            WHEN inventory_level < reorder_point                    THEN 'REORDER'
            ELSE 'OK' END AS status,
       CASE WHEN inventory_level < reorder_point
            THEN CEIL(order_up_to_level - inventory_level) ELSE 0 END AS suggested_order_qty
FROM calc;




-- 9. REPLENISHMENT SUMMARY BY STORE

SELECT store_id,
       COUNT(*)                                     AS store_products,
       COUNT(*) FILTER (WHERE status = 'CRITICAL')  AS critical,
       COUNT(*) FILTER (WHERE status = 'REORDER')   AS reorder,
       COUNT(*) FILTER (WHERE status = 'OK')        AS ok,
       SUM(suggested_order_qty)                     AS units_to_order
FROM v_replenishment
GROUP BY store_id
ORDER BY store_id;


-- 10. DATA QUALITY CHECKS

SELECT COUNT(*) FROM inventory_records;                                  -- 109500
SELECT COUNT(*) FROM inventory_records WHERE inventory_level = 0;        -- 0
SELECT COUNT(*) FROM inventory_records WHERE units_sold > inventory_level; -- 5545


-- 11. REGIONS PER STORE

SELECT store_id, COUNT(DISTINCT region) AS regions
FROM inventory_records GROUP BY store_id;                                -- 4 for every store



-- 12. HOW MANY ITEMS ARE IN EACH STATUS

SELECT status, COUNT(*) FROM v_replenishment GROUP BY status;



-- 13. MOST URGENT ITEMS

SELECT store_id, product_id, inventory_level,
       ROUND(cover_days, 2) AS cover_days, status, suggested_order_qty
FROM v_replenishment
WHERE status <> 'OK'
ORDER BY cover_days
LIMIT 10;



-- 14. WHAT IF DELIVERY TAKES 2 DAYS?

UPDATE replenishment_params SET lead_time_days = 2;

SELECT status, COUNT(*) FROM v_replenishment GROUP BY status;

UPDATE replenishment_params SET lead_time_days = 1;   -- put it back



-- 15. INVENTORY TURNOVER

SELECT store_id,
       ROUND(AVG(inventory_level) / AVG(units_sold), 2)       AS days_on_hand,
       ROUND(365 * AVG(units_sold) / AVG(inventory_level), 0) AS turns_per_year
FROM inventory_records
GROUP BY store_id;




-- 16. FORECAST BIAS AND ERROR

SELECT ROUND(AVG(demand_forecast - units_sold), 2) AS bias,
       ROUND(100.0 * SUM(ABS(demand_forecast - units_sold)) / SUM(units_sold), 2) AS error_pct
FROM inventory_records;



-- 17. FORECAST CORRECTION (LEARN ON 2022, TEST ON 2023)

SELECT SUM(units_sold) / SUM(demand_forecast) AS factor
FROM inventory_records WHERE record_date < '2023-01-01';   -- about 0.895

SELECT ROUND(100.0 * SUM(ABS(demand_forecast - units_sold)) / SUM(units_sold), 2)         AS error_before,
       ROUND(100.0 * SUM(ABS(demand_forecast * 0.895 - units_sold)) / SUM(units_sold), 2) AS error_after
FROM inventory_records WHERE record_date >= '2023-01-01';



-- 18. WHAT DRIVES SALES: PROMOTION, SEASON, DISCOUNT

SELECT holiday_promotion, ROUND(AVG(units_sold), 1) AS avg_units
FROM inventory_records GROUP BY holiday_promotion;

SELECT season, ROUND(AVG(units_sold), 1) AS avg_units
FROM inventory_records GROUP BY season;

SELECT discount_pct, ROUND(AVG(units_sold), 1) AS avg_units
FROM inventory_records GROUP BY discount_pct ORDER BY discount_pct;




-- 19. COST OF DISCOUNTS

SELECT ROUND(SUM(units_sold * price * discount_pct / 100.0) / 1000000, 1) AS discount_given_millions,
       ROUND(100.0 * SUM(units_sold * price * discount_pct / 100.0)
             / SUM(units_sold * price), 1) AS pct_given_away
FROM inventory_records;



-- 20. SALES BY CATEGORY

SELECT p.category, SUM(r.units_sold) AS units,
       ROUND(SUM(r.units_sold * r.price * (1 - r.discount_pct / 100.0)) / 1000000, 1) AS revenue_millions
FROM inventory_records r
JOIN products p ON p.product_id = r.product_id
GROUP BY p.category
ORDER BY revenue_millions DESC;



-- 21. MONTHLY SALES TREND

SELECT TO_CHAR(record_date, 'YYYY-MM') AS month, SUM(units_sold) AS units
FROM inventory_records
GROUP BY 1
ORDER BY 1;



-- 22. CRITICAL ITEMS BY CATEGORY

SELECT category, COUNT(*) AS critical_items
FROM v_replenishment
WHERE status = 'CRITICAL'
GROUP BY category
ORDER BY critical_items DESC;



-- 23. HOW OFTEN EACH STORE IS SHORT OF STOCK

SELECT store_id,
       ROUND(100.0 * COUNT(*) FILTER (WHERE inventory_level < demand_forecast) / COUNT(*), 1) AS pct_days_short
FROM inventory_records
GROUP BY store_id
ORDER BY store_id;



-- 24. PROMOTION EFFECT BY SEASON

SELECT season, holiday_promotion, ROUND(AVG(units_sold), 1) AS avg_units
FROM inventory_records
GROUP BY season, holiday_promotion
ORDER BY season, holiday_promotion;



-- 25. ORDERED VS SOLD

SELECT store_id, SUM(units_ordered) AS ordered, SUM(units_sold) AS sold,
       ROUND(100.0 * (SUM(units_ordered) - SUM(units_sold)) / SUM(units_sold), 2) AS pct_diff
FROM inventory_records
GROUP BY store_id
ORDER BY store_id;