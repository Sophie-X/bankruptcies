CREATE SCHEMA IF NOT EXISTS qa;
CREATE OR REPLACE VIEW qa.silver_sectors_without_level
AS
SELECT 
    sector_key,
    sector_title,
    sector_categorygroupid,
    level_group,
    level_description,
    level_name
FROM silver.dim_sectors
WHERE level_group IS NULL;