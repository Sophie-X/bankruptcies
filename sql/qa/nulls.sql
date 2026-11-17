CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.bronze_nulls
AS
SELECT 
    COUNT(*)                                                AS total_row_count,
    COUNT(*) - COUNT(pronouncedbankruptcies_1)              AS bankruptcies_nulls, 
    COUNT(*) - COUNT(type_key)                              AS type_nulls, 
    COUNT(*) - COUNT(sector_key)                            AS sector_nulls, 
    COUNT(*) - COUNT(period_key)                            AS period_nulls,
    COUNT(*) FILTER (where pronouncedbankruptcies_1 = 0)    AS bankruptcies_zeros
from bronze.raw_bankruptcies;