CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_nulls
AS
SELECT 
    COUNT(*)                                    AS total_row_count,
    COUNT(*) - COUNT(bankruptcies)              AS bankruptcies_nulls, 
    COUNT(*) - COUNT(bankruptcy_type_code)      AS bankruptcy_type_code_nulls, 
    COUNT(*) - COUNT(sector_code)               AS sector_code_nulls, 
    COUNT(*) - COUNT(period_key)                AS period_key_nulls,
    COUNT(*) FILTER (where bankruptcies = 0)    AS bankruptcies_zeros
from silver.bankruptcies_monthly;