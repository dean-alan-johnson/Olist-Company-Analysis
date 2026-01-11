- OLIST PERFORMANCE AUDIT (2016 - 2018)
- Analysis of Revenue Momentum, Product Strategy, and Logistics 

USE Olist;
GO

- 1. MONTHLY REVENUE & MOM GROWTH
- Aggregates price to capture total revenue; NULLIF prevents division by zero in growth calculation.
WITH MonthlyRevenue AS (
    SELECT
        YEAR(o.order_delivered_customer_date) AS year,
        MONTH(o.order_delivered_customer_date) AS month,
        SUM(oi.price) AS total_revenue
    FROM olist_order_items AS oi
    JOIN olist_orders AS o ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered' 
      AND o.order_delivered_customer_date IS NOT NULL
    GROUP BY YEAR(o.order_delivered_customer_date), MONTH(o.order_delivered_customer_date)
)
SELECT
    year, month,
    FORMAT(DATEFROMPARTS(year, month, 1), 'MM/dd/yyyy') AS formatted_date, 
    CAST(total_revenue AS DECIMAL(18,2)) AS total_revenue,
    LAG(total_revenue) OVER (ORDER BY year, month) AS prev_revenue,
    ROUND((total_revenue - LAG(total_revenue) OVER (ORDER BY year, month)) * 100.0 
    / NULLIF(LAG(total_revenue) OVER (ORDER BY year, month), 0), 2) AS mom_growth_pct
FROM MonthlyRevenue
ORDER BY year, month;


- 2. ORDER VOLUME & AOV (MASS-MARKET PIVOT)
- Uses DISTINCT order_id to prevent "fan-out" from multi-item orders during volume counting.
WITH MonthlyMetrics AS (
    SELECT
        YEAR(o.order_purchase_timestamp) AS year,
        MONTH(o.order_purchase_timestamp) AS month,
        SUM(oi.price) AS total_revenue,
        COUNT(DISTINCT o.order_id) AS total_orders
    FROM olist_order_items AS oi
    JOIN olist_orders AS o ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered' 
      AND o.order_purchase_timestamp < '2018-09-01'
    GROUP BY YEAR(o.order_purchase_timestamp), MONTH(o.order_purchase_timestamp)
)
SELECT
    year, month,
    total_orders,
    CAST(total_revenue / NULLIF(total_orders, 0) AS DECIMAL(18,2)) AS avg_order_value
FROM MonthlyMetrics
ORDER BY year, month;


- 3. CATEGORY MARKET SHARE (TOP 5 VS OTHERS)
- Evaluates the shifting dominance of anchor categories over time.
WITH CategoryPrices AS (
    SELECT 
        oi.order_id, o.order_purchase_timestamp,
        COALESCE(t.translated_name, p.product_category_name) AS category_name,
        oi.price
    FROM olist_order_items oi
    JOIN olist_orders o ON oi.order_id = o.order_id
    JOIN olist_products p ON oi.product_id = p.product_id
    LEFT JOIN product_category_name_translation t ON p.product_category_name = t.original_name
    WHERE o.order_status = 'delivered' AND o.order_purchase_timestamp < '2018-09-01'
),
Top5List AS (
    SELECT TOP 5 category_name FROM CategoryPrices 
    GROUP BY category_name ORDER BY SUM(price) DESC
),
MonthlyAggregated AS (
    SELECT 
        FORMAT(DATEFROMPARTS(YEAR(order_purchase_timestamp), MONTH(order_purchase_timestamp), 1), 'MM/dd/yyyy') AS m_date,
        CASE WHEN l.category_name IS NOT NULL THEN cp.category_name ELSE 'Others' END AS category_group,
        SUM(price) AS revenue
    FROM CategoryPrices cp
    LEFT JOIN Top5List l ON cp.category_name = l.category_name
    GROUP BY YEAR(order_purchase_timestamp), MONTH(order_purchase_timestamp), 
             CASE WHEN l.category_name IS NOT NULL THEN cp.category_name ELSE 'Others' END
)
SELECT 
    m_date, category_group,
    CAST(revenue * 100.0 / NULLIF(SUM(revenue) OVER(PARTITION BY m_date), 0) AS DECIMAL(5,2)) AS market_share_pct
FROM MonthlyAggregated
ORDER BY CAST(m_date AS DATE), market_share_pct DESC;


- 4. SENTIMENT VARIANCE (QUALITY VS VOLUME)
- Measures the variance between specific product categories and the store-wide average rating.
WITH GlobalAvg AS (
    SELECT 
        FORMAT(DATEFROMPARTS(YEAR(review_creation_date), MONTH(review_creation_date), 1), 'MM/dd/yyyy') AS f_month,
        AVG(CAST(review_score AS FLOAT)) AS avg_score
    FROM olist_order_reviews GROUP BY YEAR(review_creation_date), MONTH(review_creation_date)
),
CategoryAvg AS (
    SELECT 
        FORMAT(DATEFROMPARTS(YEAR(r.review_creation_date), MONTH(r.review_creation_date), 1), 'MM/dd/yyyy') AS f_month,
        COALESCE(t.translated_name, p.product_category_name) AS cat_name,
        AVG(CAST(r.review_score AS FLOAT)) AS cat_score
    FROM olist_order_reviews r
    JOIN olist_order_items oi ON r.order_id = oi.order_id
    JOIN olist_products p ON oi.product_id = p.product_id
    LEFT JOIN product_category_name_translation t ON p.product_category_name = t.original_name
    GROUP BY YEAR(r.review_creation_date), MONTH(r.review_creation_date), COALESCE(t.translated_name, p.product_category_name)
)
SELECT 
    c.f_month, c.cat_name, ROUND(c.cat_score, 2) AS actual_rating,
    ROUND(c.cat_score - g.avg_score, 2) AS variance_from_avg
FROM CategoryAvg c
JOIN GlobalAvg g ON c.f_month = g.f_month
WHERE c.cat_name IN ('health_beauty', 'watches_gifts', 'bed_bath_table', 'sports_leisure', 'computers_accessories')
ORDER BY CAST(c.f_month AS DATE) DESC;


- 5. LOGISTICS RELAY (THE 25/75 SPLIT)
- Analyzes handling vs transit efficiency to identify structural bottlenecks.
SELECT 
    CAST(AVG(DATEDIFF(day, order_purchase_timestamp, order_delivered_carrier_date) * 1.0) AS DECIMAL(10,1)) AS seller_handling_days,
    CAST(AVG(DATEDIFF(day, order_delivered_carrier_date, order_delivered_customer_date) * 1.0) AS DECIMAL(10,1)) AS carrier_transit_days,
    CAST(AVG(DATEDIFF(day, order_purchase_timestamp, order_delivered_customer_date) * 1.0) AS DECIMAL(10,1)) AS total_lead_time
FROM olist_orders
WHERE order_status = 'delivered' 
  AND order_delivered_carrier_date IS NOT NULL 
  AND order_delivered_customer_date >= order_delivered_carrier_date;


- 6. FREIGHT RATIO ("LOGISTICS TAX")
- Highlights how shipping costs impact the competitiveness of different product verticals.
SELECT 
    COALESCE(t.translated_name, p.product_category_name) AS category,
    CAST(AVG(oi.price) AS DECIMAL(10,2)) AS avg_item_price,
    CAST((SUM(oi.freight_value) / NULLIF(SUM(oi.price + oi.freight_value), 0)) * 100 AS DECIMAL(10,1)) AS freight_ratio_pct
FROM olist_order_items oi
JOIN olist_products p ON oi.product_id = p.product_id
LEFT JOIN product_category_name_translation t ON p.product_category_name = t.original_name
GROUP BY COALESCE(t.translated_name, p.product_category_name)
HAVING COUNT(oi.order_id) > 500
ORDER BY freight_ratio_pct ASC;