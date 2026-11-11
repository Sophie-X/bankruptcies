-- qa.silver_duplicates source
CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_duplicates
AS
SELECT count(*) as total_count, bankruptcy_type_code, sector_code, period_key
FROM silver.bankruptcies_monthly
GROUP BY bankruptcy_type_code, sector_code, period_key
HAVING count(*) > 1
;