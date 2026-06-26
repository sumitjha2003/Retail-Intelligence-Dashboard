-- ============================================================
-- RETAIL ANALYTICS PROJECT: SQL VIEWS
-- Dataset: Retail Sales (2022-2023)
-- Columns: transactions_id, sale_date, sale_time, customer_id,
--          gender, age, category, quantiy, price_per_unit,
--          cogs, total_sale
-- Database: PostgreSQL
-- Author: [Your Name] 
-- ============================================================


-- ============================================================
-- STEP 0: DATA CLEANING CHECK
-- Run this first to understand null values before creating views
-- ============================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT(transactions_id) AS valid_transaction_id,
    COUNT(age) AS valid_age,
    COUNT(quantiy) AS valid_quantity,
    COUNT(cogs) AS valid_cogs,
    COUNT(total_sale) AS valid_total_sale,
    COUNT(*) - COUNT(age) AS null_age,
    COUNT(*) - COUNT(quantiy) AS null_quantity,
    COUNT(*) - COUNT(cogs) AS null_cogs
FROM retail_sales;

-- ============================================================
-- VIEW 1: BASE CLEAN VIEW (Foundation for all other views)
-- Handles nulls, fixes typo in column name, adds derived fields
-- ============================================================

CREATE OR REPLACE VIEW vw_clean_sales AS
SELECT
    transactions_id,
    sale_date::DATE AS sale_date,
    sale_time::TIME AS sale_time,
    customer_id,
    gender,
    COALESCE(age, ROUND((AVG(age) OVER (PARTITION BY gender))::NUMERIC, 0)) AS age,
    category,
    COALESCE(quantiy, 1) AS quantity,              -- fix typo in column name
    COALESCE(price_per_unit, total_sale / NULLIF(quantiy, 0)) AS price_per_unit,
    COALESCE(cogs, 0) AS cogs,
    COALESCE(total_sale, price_per_unit * quantiy) AS total_sale,

    -- Derived: Profit Metrics
    COALESCE(total_sale, 0) - COALESCE(cogs, 0) AS gross_profit,
    ROUND(
        (
        (COALESCE(total_sale, 0) - COALESCE(cogs, 0))
        / NULLIF(COALESCE(total_sale, 0), 0) * 100
        )::NUMERIC, 2
    ) AS profit_margin_pct,

    -- Derived: Time Dimensions
    EXTRACT(YEAR FROM sale_date::DATE)                     AS year,
    EXTRACT(MONTH FROM sale_date::DATE)                    AS month_num,
    TO_CHAR(sale_date::DATE, 'Month')                      AS month_name,
    TO_CHAR(sale_date::DATE, 'YYYY-MM')                    AS year_month,
    EXTRACT(QUARTER FROM sale_date::DATE)                  AS quarter,
    'Q' || EXTRACT(QUARTER FROM sale_date::DATE)::TEXT     AS quarter_label,
    TO_CHAR(sale_date::DATE, 'Day')                        AS day_of_week,
    EXTRACT(DOW FROM sale_date::DATE)                      AS day_num,   -- 0=Sunday
    EXTRACT(HOUR FROM sale_time::TIME)                     AS hour_of_day,

    -- Derived: Time-of-Day Bucket
    CASE
        WHEN EXTRACT(HOUR FROM sale_time::TIME) BETWEEN 6  AND 11 THEN 'Morning (6am-12pm)'
        WHEN EXTRACT(HOUR FROM sale_time::TIME) BETWEEN 12 AND 16 THEN 'Afternoon (12pm-5pm)'
        WHEN EXTRACT(HOUR FROM sale_time::TIME) BETWEEN 17 AND 20 THEN 'Evening (5pm-9pm)'
        ELSE 'Night (9pm+)'
    END AS time_of_day,

    -- Derived: Age Segments
    CASE
        WHEN COALESCE(age, 0) BETWEEN 18 AND 25 THEN '18-25 (Gen Z)'
        WHEN COALESCE(age, 0) BETWEEN 26 AND 35 THEN '26-35 (Young Millennial)'
        WHEN COALESCE(age, 0) BETWEEN 36 AND 45 THEN '36-45 (Senior Millennial)'
        WHEN COALESCE(age, 0) BETWEEN 46 AND 55 THEN '46-55 (Gen X)'
        WHEN COALESCE(age, 0) BETWEEN 56 AND 64 THEN '56-64 (Boomer)'
        ELSE 'Unknown'
    END AS age_group,

    -- Derived: Transaction Size Bucket
    CASE
        WHEN COALESCE(total_sale, 0) < 100  THEN 'Small (<100)'
        WHEN COALESCE(total_sale, 0) < 500  THEN 'Medium (100-499)'
        WHEN COALESCE(total_sale, 0) < 1000 THEN 'Large (500-999)'
        ELSE 'Premium (1000+)'
    END AS transaction_tier

FROM retail_sales
WHERE total_sale IS NOT NULL;


-- ============================================================
-- VIEW 2: MONTHLY SALES TREND
-- Used for: Line chart, YoY comparison
-- ============================================================

CREATE OR REPLACE VIEW vw_monthly_sales AS
SELECT
    year,
    month_num,
    month_name,
    year_month,
    quarter_label,
    COUNT(transactions_id)       AS total_transactions,
    COUNT(DISTINCT customer_id)  AS unique_customers,
    SUM(total_sale)              AS total_revenue,
    SUM(gross_profit)            AS total_profit,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2) AS avg_margin_pct,
    ROUND(AVG(total_sale)::NUMERIC, 2)    AS avg_order_value,
    SUM(quantity)                AS total_units_sold
FROM vw_clean_sales
GROUP BY year, month_num, month_name, year_month, quarter_label
ORDER BY year, month_num;


-- ============================================================
-- VIEW 3: YEAR-OVER-YEAR COMPARISON (2022 vs 2023)
-- Used for: Comparison cards, growth % visuals
-- ============================================================

CREATE OR REPLACE VIEW vw_yoy_comparison AS
WITH monthly AS (
    SELECT
        month_num,
        month_name,
        year,
        SUM(total_sale) AS revenue,
        COUNT(transactions_id) AS transactions
    FROM vw_clean_sales
    GROUP BY month_num, month_name, year
),
pivot AS (
    SELECT
        month_num,
        month_name,
        MAX(CASE WHEN year = 2022 THEN revenue      ELSE 0 END) AS revenue_2022,
        MAX(CASE WHEN year = 2023 THEN revenue      ELSE 0 END) AS revenue_2023,
        MAX(CASE WHEN year = 2022 THEN transactions ELSE 0 END) AS txns_2022,
        MAX(CASE WHEN year = 2023 THEN transactions ELSE 0 END) AS txns_2023
    FROM monthly
    GROUP BY month_num, month_name
)
SELECT
    month_num,
    month_name,
    revenue_2022,
    revenue_2023,
    revenue_2023 - revenue_2022                                    AS revenue_growth,
    ROUND(((revenue_2023 - revenue_2022) / NULLIF(revenue_2022, 0) * 100)::NUMERIC, 2) AS revenue_growth_pct,
    txns_2022,
    txns_2023
FROM pivot
ORDER BY month_num;


-- ============================================================
-- VIEW 4: CATEGORY PERFORMANCE
-- Used for: Bar chart, donut chart, treemap
-- ============================================================

CREATE OR REPLACE VIEW vw_category_performance AS
SELECT
    category,
    COUNT(transactions_id)                            AS total_transactions,
    COUNT(DISTINCT customer_id)                       AS unique_customers,
    SUM(total_sale)                                   AS total_revenue,
    SUM(gross_profit)                                 AS total_profit,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2)                  AS avg_margin_pct,
    ROUND(AVG(total_sale)::NUMERIC, 2)                         AS avg_order_value,
    SUM(quantity)                                     AS units_sold,
    ROUND(AVG(price_per_unit)::NUMERIC, 2)                     AS avg_price_per_unit,
    ROUND((SUM(total_sale) * 100.0 /
          SUM(SUM(total_sale)) OVER ())::NUMERIC, 2)            AS revenue_share_pct
FROM vw_clean_sales
GROUP BY category
ORDER BY total_revenue DESC;


-- ============================================================
-- VIEW 5: CATEGORY BY TIME (Monthly Category Trend)
-- Used for: Stacked bar chart showing category trends over time
-- ============================================================

CREATE OR REPLACE VIEW vw_category_monthly_trend AS
SELECT
    year_month,
    year,
    month_num,
    month_name,
    category,
    SUM(total_sale)          AS revenue,
    COUNT(transactions_id)   AS transactions,
    SUM(gross_profit)        AS profit,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2) AS margin_pct
FROM vw_clean_sales
GROUP BY year_month, year, month_num, month_name, category
ORDER BY year, month_num, category;


-- ============================================================
-- VIEW 6: CUSTOMER SUMMARY (360-degree customer view)
-- Used for: Customer ranking, CLV analysis
-- ============================================================

CREATE OR REPLACE VIEW vw_customer_summary AS
SELECT
    customer_id,
    gender,
    MAX(age)                              AS age,
    MAX(age_group)                        AS age_group,
    MIN(sale_date)                        AS first_purchase_date,
    MAX(sale_date)                        AS last_purchase_date,
    MAX(sale_date) - MIN(sale_date)       AS customer_tenure_days,
    COUNT(transactions_id)                AS total_transactions,
    SUM(total_sale)                       AS total_revenue,
    SUM(gross_profit)                     AS total_profit,
    ROUND(AVG(total_sale)::NUMERIC, 2)             AS avg_order_value,
    SUM(quantity)                         AS total_units_purchased,
    COUNT(DISTINCT category)              AS categories_purchased,
    MODE() WITHIN GROUP (ORDER BY category) AS preferred_category,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2)      AS avg_margin_pct,
    CURRENT_DATE - MAX(sale_date)         AS days_since_last_purchase
FROM vw_clean_sales
GROUP BY customer_id, gender
ORDER BY total_revenue DESC;


-- ============================================================
-- VIEW 7: GENDER ANALYSIS
-- Used for: Stacked bar, donut charts comparing M vs F behavior
-- ============================================================

CREATE OR REPLACE VIEW vw_gender_analysis AS
SELECT
    gender,
    category,
    COUNT(transactions_id)       AS total_transactions,
    SUM(total_sale)              AS total_revenue,
    ROUND(AVG(total_sale)::NUMERIC, 2)    AS avg_order_value,
    SUM(quantity)                AS units_sold,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2) AS avg_margin_pct,
    COUNT(DISTINCT customer_id)  AS unique_customers
FROM vw_clean_sales
GROUP BY gender, category
ORDER BY gender, total_revenue DESC;


-- ============================================================
-- VIEW 8: AGE GROUP ANALYSIS
-- Used for: Horizontal bar chart, heatmap by age × category
-- ============================================================

CREATE OR REPLACE VIEW vw_age_analysis AS
SELECT
    age_group,
    category,
    COUNT(transactions_id)       AS total_transactions,
    SUM(total_sale)              AS total_revenue,
    ROUND(AVG(total_sale)::NUMERIC, 2)    AS avg_order_value,
    SUM(quantity)                AS units_sold,
    COUNT(DISTINCT customer_id)  AS unique_customers
FROM vw_clean_sales
GROUP BY age_group, category
ORDER BY
    CASE age_group
        WHEN '18-25 (Gen Z)' THEN 1
        WHEN '26-35 (Young Millennial)' THEN 2
        WHEN '36-45 (Senior Millennial)' THEN 3
        WHEN '46-55 (Gen X)' THEN 4
        WHEN '56-64 (Boomer)' THEN 5
    END,
    total_revenue DESC;


-- ============================================================
-- VIEW 9: HOURLY / TIME-OF-DAY SALES PATTERN
-- Used for: Heatmap, bar chart of peak shopping hours
-- ============================================================

CREATE OR REPLACE VIEW vw_time_of_day_analysis AS
SELECT
    hour_of_day,
    time_of_day,
    day_of_week,
    day_num,
    COUNT(transactions_id)       AS total_transactions,
    SUM(total_sale)              AS total_revenue,
    ROUND(AVG(total_sale)::NUMERIC, 2)    AS avg_order_value,
    SUM(quantity)                AS units_sold
FROM vw_clean_sales
GROUP BY hour_of_day, time_of_day, day_of_week, day_num
ORDER BY hour_of_day, day_num;


-- ============================================================
-- VIEW 10: QUARTERLY PERFORMANCE SUMMARY
-- Used for: Quarter-wise KPI cards
-- ============================================================

CREATE OR REPLACE VIEW vw_quarterly_performance AS
SELECT
    year,
    quarter,
    quarter_label,
    year::TEXT || '-' || quarter_label AS year_quarter,
    COUNT(transactions_id)              AS total_transactions,
    COUNT(DISTINCT customer_id)         AS unique_customers,
    SUM(total_sale)                     AS total_revenue,
    SUM(gross_profit)                   AS total_profit,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2)    AS avg_margin_pct,
    ROUND(AVG(total_sale)::NUMERIC, 2)           AS avg_order_value
FROM vw_clean_sales
GROUP BY year, quarter, quarter_label
ORDER BY year, quarter;


-- ============================================================
-- VIEW 11: PROFITABILITY HEATMAP (Category × Month)
-- Used for: Matrix visual in Power BI showing margin hotspots
-- ============================================================

CREATE OR REPLACE VIEW vw_profitability_heatmap AS
SELECT
    year,
    month_num,
    month_name,
    year_month,
    category,
    SUM(total_sale)                 AS revenue,
    SUM(cogs)                       AS total_cogs,
    SUM(gross_profit)               AS gross_profit,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2) AS margin_pct,
    COUNT(transactions_id)          AS transactions
FROM vw_clean_sales
GROUP BY year, month_num, month_name, year_month, category
ORDER BY year, month_num, category;


-- ============================================================
-- VIEW 12: RFM CUSTOMER SEGMENTATION
-- R = Recency (days since last purchase — lower is better)
-- F = Frequency (number of purchases — higher is better)
-- M = Monetary (total spend — higher is better)
-- ============================================================

-- Step 12a: Calculate raw RFM values
CREATE OR REPLACE VIEW vw_rfm_raw AS
SELECT
    customer_id,
    gender,
    MAX(age)                                     AS age,
    MAX(age_group)                               AS age_group,
    CURRENT_DATE - MAX(sale_date)                AS recency_days,
    COUNT(transactions_id)                       AS frequency,
    SUM(total_sale)                              AS monetary
FROM vw_clean_sales
GROUP BY customer_id, gender;

-- Step 12b: Score each dimension 1-5 using NTILE
CREATE OR REPLACE VIEW vw_rfm_scores AS
SELECT
    customer_id,
    gender,
    age,
    age_group,
    recency_days,
    frequency,
    monetary,

    -- R: Lower recency is BETTER, so we invert (NTILE 1 = most recent = score 5)
    6 - NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,

    -- F: Higher frequency is BETTER
    NTILE(5) OVER (ORDER BY frequency ASC)         AS f_score,

    -- M: Higher monetary is BETTER
    NTILE(5) OVER (ORDER BY monetary ASC)          AS m_score
FROM vw_rfm_raw;

-- Step 12c: Combine scores and assign segments
CREATE OR REPLACE VIEW vw_rfm_segments AS
SELECT
    customer_id,
    gender,
    age,
    age_group,
    recency_days,
    frequency,
    ROUND(monetary::NUMERIC, 2) AS monetary,
    r_score,
    f_score,
    m_score,
    (r_score + f_score + m_score)                  AS rfm_total_score,
    CONCAT(r_score::TEXT, f_score::TEXT, m_score::TEXT) AS rfm_code,

    -- Business Segment Labels
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4
            THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3
            THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2
            THEN 'Promising (New)'
        WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 4
            THEN 'At Risk'
        WHEN r_score <= 2 AND f_score >= 3
            THEN 'Need Attention'
        WHEN r_score >= 3 AND f_score >= 3 AND m_score <= 2
            THEN 'Potential Loyalists'
        WHEN r_score <= 2 AND f_score <= 2 AND m_score <= 2
            THEN 'Lost / Churned'
        ELSE 'Others'
    END AS customer_segment,

    -- Actionable Priority
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4
            THEN 1  -- Top priority: reward and retain
        WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 4
            THEN 2  -- High value but drifting
        WHEN r_score >= 4 AND f_score <= 2
            THEN 3  -- New promising
        ELSE 4
    END AS action_priority

FROM vw_rfm_scores;


-- ============================================================
-- VIEW 13: TRANSACTION SIZE DISTRIBUTION
-- Used for: Histogram-style bar chart in Power BI
-- ============================================================

CREATE OR REPLACE VIEW vw_transaction_distribution AS
SELECT
    transaction_tier,
    category,
    gender,
    COUNT(transactions_id)       AS count_of_transactions,
    SUM(total_sale)              AS total_revenue,
    ROUND(AVG(total_sale)::NUMERIC, 2)    AS avg_sale_value,
    ROUND((COUNT(transactions_id) * 100.0 /
          SUM(COUNT(transactions_id)) OVER ())::NUMERIC, 2) AS pct_of_total
FROM vw_clean_sales
GROUP BY transaction_tier, category, gender
ORDER BY
    CASE transaction_tier
        WHEN 'Small (<100)'     THEN 1
        WHEN 'Medium (100-499)' THEN 2
        WHEN 'Large (500-999)'  THEN 3
        WHEN 'Premium (1000+)'  THEN 4
    END;


-- ============================================================
-- VIEW 14: EXECUTIVE SUMMARY KPIs
-- Used for: Power BI KPI cards on Page 1
-- ============================================================

CREATE OR REPLACE VIEW vw_executive_kpis AS
SELECT
    COUNT(transactions_id)                     AS total_transactions,
    COUNT(DISTINCT customer_id)                AS total_customers,
    SUM(total_sale)                            AS total_revenue,
    SUM(gross_profit)                          AS total_gross_profit,
    ROUND(AVG(profit_margin_pct)::NUMERIC, 2)           AS avg_profit_margin_pct,
    ROUND(AVG(total_sale)::NUMERIC, 2)                  AS avg_order_value,
    SUM(quantity)                              AS total_units_sold,
    MIN(sale_date)                             AS data_start_date,
    MAX(sale_date)                             AS data_end_date,
    COUNT(DISTINCT year_month)                 AS months_of_data,

    -- Revenue per customer
    ROUND((SUM(total_sale) / COUNT(DISTINCT customer_id))::NUMERIC, 2) AS revenue_per_customer,

    -- Avg transactions per customer
    ROUND(COUNT(transactions_id)::NUMERIC / COUNT(DISTINCT customer_id), 2) AS avg_txns_per_customer
FROM vw_clean_sales;


-- ============================================================
-- QUICK VALIDATION QUERIES
-- Run these to confirm your views are working correctly
-- ============================================================

-- Test 1: Total revenue should be ~911,720
SELECT SUM(total_sale) FROM vw_clean_sales;

-- Test 2: Should see 3 categories
SELECT category, COUNT(*) FROM vw_clean_sales GROUP BY category;

-- Test 3: Should see 5 customer segments
SELECT customer_segment, COUNT(*) FROM vw_rfm_segments GROUP BY customer_segment ORDER BY COUNT(*) DESC;

-- Test 4: Executive KPIs
SELECT * FROM vw_executive_kpis;
