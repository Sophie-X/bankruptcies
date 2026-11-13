CREATE OR REPLACE VIEW silver.dim_periods
AS 
WITH 
	p AS (
	    SELECT 
            TRIM(key) AS period_key,
            RIGHT(LEFT(TRIM(key), 6), 2)::text AS period_type
	    FROM bronze.raw_periods
	)
SELECT
    p.period_key,                                                              
    p.period_type,                                                          
    CASE
        WHEN p.period_type = 'MM'        THEN make_date(left(p.period_key, 4)::int, right(p.period_key, 2)::int,1)
        WHEN p.period_type = 'KW'        THEN make_date(left(p.period_key, 4)::int, (right(p.period_key, 2)::int * 3) - 2, 1)
        WHEN p.period_type = 'JJ'        THEN make_date(left(p.period_key, 4)::int, 1, 1)
        END                                                                 AS period_date,
    lp.status                                                               AS period_status,
    COALESCE(lp.status <> 'Definitief', true)                               AS is_provisional
FROM p
LEFT JOIN control.load_periods lp
ON trim(lp.period_key) = p.period_key;