CREATE SCHEMA IF NOT EXISTS analysis;
CREATE OR REPLACE VIEW analysis.zero_profile_per_sector_type
AS
SELECT
    ds.level_group,
    ds.level_name,
	ds.sector_title,
    dbt.type_title,
    ds.sector_key,
    dbt.type_key,
    COUNT(*) AS total_months,
    SUM(CASE WHEN fb.bankruptcies = 0 THEN 1 ELSE 0 END) AS zero_months,
    SUM(CASE WHEN fb.bankruptcies = 0 THEN 1 ELSE 0 END) / COUNT(*)::float AS share_of_zeros,
    AVG(fb.bankruptcies) AS average_count
    FROM silver.fact_bankruptcies fb
    JOIN silver.dim_periods dp ON fb.period_key = dp.period_key
    JOIN silver.dim_sectors ds ON fb.sector_key = ds.sector_key
    JOIN silver.dim_typesofbankruptcies dbt ON fb.type_key = dbt.type_key
    WHERE dp.period_type = 'MM'
    GROUP BY ds.level_group, ds.level_name, ds.sector_key, dbt.type_key, ds.sector_title, dbt.type_title
    order by share_of_zeros desc