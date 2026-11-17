CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_dimension_meaning_drift
AS 
WITH
    s AS (
        SELECT  
        COUNT(*) AS occurrences,
        TRIM(rb.sector_key) AS dimension_key,
        rb.sectorbranchessic2008 AS loaded_title,
        ds.sector_title AS reference_title,
        'sector' AS list,
        MIN(TRIM(rb.period_key)) AS first_period,
        MAX(TRIM(rb.period_key)) AS last_period
        FROM bronze.raw_bankruptcies rb
        INNER JOIN silver.dim_sectors ds
        ON TRIM(rb.sector_key) = ds.sector_key
        WHERE rb.sectorbranchessic2008 IS DISTINCT FROM ds.sector_title
        GROUP BY TRIM(rb.sector_key), rb.sectorbranchessic2008, ds.sector_title
    ),
    p AS (
        SELECT 
        COUNT(*) AS occurrences,
        TRIM(rb.period_key) AS dimension_key,
        rb.periods AS loaded_title,
        dp.period_title AS reference_title,
        'period' AS list,
        MIN(TRIM(rb.period_key)) AS first_period,
        MAX(TRIM(rb.period_key)) AS last_period
        FROM bronze.raw_bankruptcies rb
        INNER JOIN silver.dim_periods dp
        ON TRIM(rb.period_key) = dp.period_key
        WHERE rb.periods IS DISTINCT FROM dp.period_title
        GROUP BY TRIM(rb.period_key), rb.periods, dp.period_title
    ),
    t AS (
        SELECT 
        COUNT(*) AS occurrences,
        TRIM(rb.type_key) AS dimension_key,
        rb.typeofbankruptcy AS loaded_title,
        dt.type_title AS reference_title,
        'type' AS list,
        MIN(TRIM(rb.period_key)) AS first_period,
        MAX(TRIM(rb.period_key)) AS last_period
        FROM bronze.raw_bankruptcies rb
        INNER JOIN silver.dim_typesofbankruptcies dt
        ON TRIM(rb.type_key) = dt.type_key
        WHERE rb.typeofbankruptcy IS DISTINCT FROM dt.type_title
        GROUP BY TRIM(rb.type_key), rb.typeofbankruptcy, dt.type_title
    )
SELECT dimension_key, loaded_title, reference_title, occurrences, list, first_period, last_period FROM s
UNION ALL 
SELECT dimension_key, loaded_title, reference_title, occurrences, list, first_period, last_period FROM p
UNION ALL 
SELECT dimension_key, loaded_title, reference_title, occurrences, list, first_period, last_period FROM t
;