CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_duplicate_facts
AS
SELECT count(*) as total_count, type_key, sector_key, period_key
FROM silver.fact_bankruptcies
GROUP BY type_key, sector_key, period_key
HAVING count(*) > 1
;