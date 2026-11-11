CREATE OR REPLACE VIEW silver.bankruptcies_monthly
AS 
WITH 
	s AS (
		SELECT TRIM(key) AS key, title, categorygroupid
	    FROM bronze.dim_sectorbranchessic2008
	),
	t AS (
		SELECT TRIM(key) AS key, title, description
	    FROM bronze.dim_typeofbankruptcy
	),
	lp AS (
	    SELECT TRIM(period_key) AS period_key, status
	    FROM control.load_periods
	),
	b AS (
	    SELECT TRIM(period_key) AS period_key,
	      TRIM(sector_key) AS sector_key,
	      TRIM(type_key) AS type_key,
	      typeofbankruptcy,
	      pronouncedbankruptcies_1
	    FROM bronze.raw_bankruptcies
	)
SELECT
    t.key                                                                   AS bankruptcy_type_code,
    b.typeofbankruptcy                                                      AS bankruptcy_type,
    s.key                                                                   AS sector_code,
    s.title                                                                 AS sector_description,
    b.period_key,
    make_date(left(b.period_key, 4)::int, right(b.period_key, 2)::int, 1)   AS period_date,
    lp.status                                                               AS period_status,
    COALESCE(lp.status <> 'Definitief', true)                               AS is_provisional,
    b.pronouncedbankruptcies_1::int                                         AS bankruptcies
FROM b
JOIN s ON s.key = b.sector_key
JOIN t ON t.key = b.type_key
JOIN bronze.dim_categorygroups cg ON cg.id = s.categorygroupid
LEFT JOIN lp ON lp.period_key = b.period_key
WHERE b.period_key LIKE '____MM__';                  


/* OLD VERSION FROM DBEAVER QUERY AND SOURCE - 20261106SJ corrected for title -> id
CREATE OR REPLACE VIEW silver.bankruptcies_monthly
AS SELECT b.typeofbankruptcy AS bankruptcy_type,
    b.sectorbranchessic2008 AS sector_description,
    b.period_key,
    b.periods AS period,
    make_date("left"(b.period_key, 4)::integer, "right"(b.period_key, 2)::integer, 1) AS period_date,
    lp.status AS period_status,
    lp.status <> 'Definitief'::text AS is_provisional,
    b.pronouncedbankruptcies_1::integer AS bankruptcies,
    s.key AS sector_code
   FROM bronze.raw_bankruptcies b
     JOIN bronze.dim_sectorbranchessic2008 s ON s.title = b.sectorbranchessic2008
     JOIN bronze.dim_categorygroups cg ON cg.id = s.categorygroupid
     LEFT JOIN control.load_periods lp ON lp.period_key = b.period_key
  WHERE b.period_key ~~ '%MM%'::text AND cg.parentid = 2::double precision;