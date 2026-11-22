CREATE OR REPLACE VIEW silver.dim_sectors
AS 
SELECT
    TRIM(s.key)                                                 AS sector_key,
    s.title                                                     AS sector_title, 
    s.categorygroupid                                           AS sector_categorygroupid,
    sl.root_group_id                                            AS level_group,
    sl.root_title                                               AS level_description,
    sl.level_name                                               AS level_name   
FROM bronze.raw_82244eng_sectorbranchessic2008 s
LEFT JOIN bronze.raw_82244eng_categorygroups c
ON c.id = s.categorygroupid
LEFT JOIN control.sector_levels sl
ON COALESCE(c.parentid, c.id) = sl.root_group_id;