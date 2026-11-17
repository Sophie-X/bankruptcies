CREATE OR REPLACE VIEW qa.freshness_check
AS
SELECT 
    'silver.fact_bankruptcies' AS table_name,
    MAX(sp.period) AS last_fact_period,
    MAX(sp.period) AS last_reference_period
FROM silver.fact_bankruptcies sb
JOIN silver.dim_periods sp
    ON sb.period_key = sp.period_key
