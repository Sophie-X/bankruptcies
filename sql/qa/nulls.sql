CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_nulls
AS
SELECT 
    COUNT(*)                                    AS total_row_count,
    COUNT(*) - COUNT(bankruptcies)              AS bankruptcies_nulls, 
    COUNT(*) - COUNT(type_key)                  AS type_nulls, 
    COUNT(*) - COUNT(sector_key)                AS sector_nulls, 
    COUNT(*) - COUNT(period_key)                AS period_nulls,
    COUNT(*) FILTER (where bankruptcies = 0)    AS bankruptcies_zeros
from silver.fact_bankruptcies;