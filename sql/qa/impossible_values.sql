CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_impossible_values
AS
SELECT
    period_key,
    sector_key,
    type_key,
    bankruptcies
from silver.fact_bankruptcies
WHERE bankruptcies < 0
;