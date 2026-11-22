CREATE SCHEMA IF NOT EXISTS control;
CREATE TABLE IF NOT EXISTS control.type_totals (
    type_key text NOT NULL,
    table_loaded text NOT NULL,
    is_total boolean NOT NULL,
    CONSTRAINT type_totals_pkey PRIMARY KEY (type_key, table_loaded)
    );
INSERT INTO control.type_totals
    (type_key, table_loaded, is_total)
    VALUES
    ('A047596', '82244ENG', 'true'),
    ('A028820', '82244ENG', 'false'),
    ('A047597', '82244ENG', 'false'),
    ('T001243', '83085ENG', 'true'),
    ('A041718', '83085ENG', 'false'),
    ('A028820', '83085ENG', 'false'),
    ('A047597', '83085ENG', 'false')
ON CONFLICT (type_key, table_loaded) DO UPDATE SET 
    is_total = EXCLUDED.is_total