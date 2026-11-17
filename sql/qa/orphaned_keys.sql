CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_orphaned_keys
AS
WITH 
    t AS ( 
        SELECT 
        f.type_key AS dimension_key,
        'type' AS list,
        count(*) AS occurrences
    FROM silver.fact_bankruptcies f
    WHERE NOT EXISTS (
        SELECT 1
        FROM silver.dim_typesofbankruptcies t
        WHERE t.type_key = f.type_key
        )
    GROUP BY f.type_key, list
    ),
   p AS ( 
        SELECT 
        f.period_key AS dimension_key,
        'period' AS list,
        count(*) AS occurrences
    FROM silver.fact_bankruptcies f
    WHERE NOT EXISTS (
        SELECT 1
        FROM silver.dim_periods p
        WHERE p.period_key = f.period_key
        )
    GROUP BY f.period_key, list
    ),
    s AS ( 
        SELECT 
        f.sector_key AS dimension_key,
        'sector' AS list,
        count(*) AS occurrences
    FROM silver.fact_bankruptcies f
    WHERE NOT EXISTS (
        SELECT 1
        FROM silver.dim_sectors s
        WHERE s.sector_key = f.sector_key
        )
    GROUP BY f.sector_key, list
    )   
SELECT dimension_key, list, occurrences FROM t
UNION ALL   
SELECT dimension_key, list, occurrences FROM p
UNION ALL
SELECT dimension_key, list, occurrences FROM s
;
    