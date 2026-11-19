CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_total_type
AS
WITH t as (SELECT
    period_key,
    sector_key,
	SUM(bankruptcies) filter (where type_key = 'A047596') as A047596_bankruptcies,
    SUM(bankruptcies) filter (where type_key IN ('A047597', 'A028820')) as A028820_and_A047597_bankruptcies
    from silver.fact_bankruptcies
    group by period_key, sector_key)
SELECT 
	period_key,
    sector_key,
    A047596_bankruptcies - A028820_and_A047597_bankruptcies as difference
    FROM t
    WHERE A047596_bankruptcies - A028820_and_A047597_bankruptcies is distinct from 0
;