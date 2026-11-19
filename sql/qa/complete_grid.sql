CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_complete_grid
AS
WITH 
    monthly as (
        SELECT
            b.sector_key,
            b.type_key,
            b.period_key,
            p.period_type,
            p.period_date
            from silver.fact_bankruptcies b
            INNER JOIN silver.dim_periods p
            ON b.period_key = p.period_key
            WHERE p.period_type = 'MM'
    ),
	minmax AS (
        SELECT
            MIN(monthly.period_date) AS min_period_date,
            MAX(monthly.period_date) AS max_period_date,
            (extract(year from MAX(monthly.period_date)) * 12 + extract(month from MAX(monthly.period_date))) - (extract(year from MIN(monthly.period_date)) * 12 + extract(month from MIN(monthly.period_date))) + 1 AS total_time_span
            from monthly
        )
SELECT
    monthly.sector_key,
    monthly.type_key,
    MIN(monthly.period_date) AS min_period_date,
    MAX(monthly.period_date) AS max_period_date,
    COUNT(DISTINCT monthly.period_key) AS months_present,
    minmax.total_time_span
FROM minmax, monthly
GROUP BY monthly.sector_key, monthly.type_key, minmax.total_time_span
HAVING COUNT(DISTINCT monthly.period_key) <> total_time_span