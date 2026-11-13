CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_duplicate_dimensions
AS
WITH
    s AS (
        SELECT
        sector_key AS dimension_key,
        COUNT(*) as occurrences,
        'sector' AS list
        FROM silver.dim_sectors
        GROUP BY sector_key, list
        HAVING COUNT(*) > 1
    ),
    p AS (
        SELECT
        period_key AS dimension_key,
        COUNT(*) as occurrences,
        'period' AS list
        FROM silver.dim_periods
        GROUP BY period_key, list
        HAVING COUNT(*) > 1
    ),
    t AS (
        SELECT
        type_key AS dimension_key,
        COUNT(*) as occurrences,
        'type' AS list
        FROM silver.dim_typesofbankruptcies
        GROUP BY type_key, list
        HAVING COUNT(*) > 1
    )
SELECT dimension_key, occurrences, list FROM s
UNION ALL 
SELECT dimension_key, occurrences, list FROM p
UNION ALL 
SELECT dimension_key, occurrences, list FROM t
;
