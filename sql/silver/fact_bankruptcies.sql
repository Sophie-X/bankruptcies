CREATE OR REPLACE VIEW silver.fact_bankruptcies
AS 
SELECT 
    TRIM(period_key) AS period_key,
	TRIM(sector_key) AS sector_key,
	TRIM(type_key) AS type_key,
	pronouncedbankruptcies_1 AS bankruptcies
FROM bronze.raw_bankruptcies
WHERE pronouncedbankruptcies_1 >= 0;