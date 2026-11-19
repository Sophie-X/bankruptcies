CREATE OR REPLACE VIEW analysis.zero_profile_per_sector_level AS
SELECT
    s.level_group,
    s.level_name,
    COUNT(*) AS series,
    SUM(s.total_months) as total_months,
    SUM(s.zero_months) as zero_months,
    ROUND((SUM(zero_months) / SUM(total_months)) * 100, 1) as share_of_zeros_percentage,
    COUNT(*) FILTER (WHERE share_of_zeros > 0.5) as sections_empty
    FROM analysis.zero_profile_per_sector_type s
    group by level_group, level_name
    order by level_name
