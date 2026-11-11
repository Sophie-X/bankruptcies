CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_row_counts
AS
SELECT 
    (SELECT COUNT(*) FROM bronze.raw_bankruptcies WHERE period_key LIKE '____MM__') as bronze_count,
    (SELECT COUNT(*) FROM silver.bankruptcies_monthly) as silver_count
;