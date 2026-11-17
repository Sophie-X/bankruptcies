CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.bronze_negative_counts
AS
SELECT
    id,
    sector_key,
    sectorbranchessic2008,
    periods,
    period_key,
    type_key,
    typeofbankruptcy,
    pronouncedbankruptcies_1 AS bankruptcies
from bronze.raw_bankruptcies
WHERE pronouncedbankruptcies_1 < 0
;