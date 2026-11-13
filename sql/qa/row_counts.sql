CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_row_counts
AS
SELECT 
    (SELECT COUNT(*) FROM bronze.raw_bankruptcies) as bronze_count,
    (SELECT COUNT(*) FROM silver.fact_bankruptcies) as silver_count
;