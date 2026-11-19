CREATE OR REPLACE VIEW qa.silver_freshness_check
AS
WITH
    sp AS (
        SELECT 
            MAX(sp.period_date) AS last_reference_date
        FROM silver.dim_periods sp
        WHERE sp.period_type = 'MM' 
    ),
    sb AS (
        SELECT 
            MAX(dp.period_date) AS last_fact_date
        FROM silver.fact_bankruptcies sb
        JOIN silver.dim_periods dp ON sb.period_key = dp.period_key
        WHERE dp.period_type = 'MM'
    ),
    cl AS (
        SELECT 
            MAX(stopped_at::date) AS last_load_date
        FROM control.load_runs
    ),
    sq AS (
        SELECT
        sp.last_reference_date,
        sb.last_fact_date,
        cl.last_load_date,
        current_date - cl.last_load_date AS load_freshness_days,
        ((EXTRACT(YEAR FROM current_date) - EXTRACT(YEAR FROM sb.last_fact_date)) * 12 + (EXTRACT(MONTH FROM current_date) - EXTRACT(MONTH FROM sb.last_fact_date)))::int AS fact_months_behind_today,
        ((EXTRACT(YEAR FROM sp.last_reference_date) - EXTRACT(YEAR FROM sb.last_fact_date)) * 12 + (EXTRACT(MONTH FROM sp.last_reference_date) - EXTRACT(MONTH FROM sb.last_fact_date)))::int AS fact_vs_reference_freshness_months
        FROM sp, sb, cl
    )
SELECT 
    CASE
        WHEN sq.last_load_date IS NULL THEN 'No load runs found'
        WHEN sq.last_fact_date IS NULL THEN 'Fact table is empty'
        WHEN sq.last_reference_date IS NULL THEN 'Reference table is empty'
        WHEN sq.load_freshness_days < 0 THEN 'Load run is fresher than today'
        WHEN sq.load_freshness_days > 40 THEN 'Load run is older than 40 days'
        WHEN sq.fact_vs_reference_freshness_months < 0 THEN 'Fact table is fresher than reference table'
        WHEN sq.fact_vs_reference_freshness_months > 0 THEN 'Reference table is fresher than fact table'
        WHEN sq.fact_months_behind_today < 0 THEN 'Fact table is fresher than today'
        WHEN sq.fact_months_behind_today > 2 THEN 'Fact table is more than 2 months behind today'
        ELSE 'OK'
    END AS freshness_status,
    sq.last_reference_date,
    sq.last_fact_date,
    sq.last_load_date,
    sq.load_freshness_days,
    sq.fact_months_behind_today,
    sq.fact_vs_reference_freshness_months
FROM sq
;