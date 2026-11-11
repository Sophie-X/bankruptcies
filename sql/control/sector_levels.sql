CREATE TABLE  IF NOT EXISTS control.sector_levels (
    root_group_id int PRIMARY KEY,
    root_title text NOT NULL,
    level_name text NOT NULL
);
INSERT INTO control.sector_levels
    (root_group_id, root_title, level_name)
    VALUES
    (0, 'total', 'sbi_0'),
    (2, 'Branches 1st digit (SIC 2008)', 'sbi_1'),
    (5, 'Branches 2nd digit (SIC 2008)', 'sbi_2'),
    (7, 'Branches 3rd digit (SIC 2008)', 'sbi_3')
ON CONFLICT (root_group_id) DO UPDATE SET ...
;