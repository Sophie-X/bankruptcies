CREATE TABLE IF NOT EXISTS control.load_periods (
	period_key text NOT NULL,
	status text NULL,
	loaded_at timestamptz NULL,
    table_loaded text NOT NULL,
    CONSTRAINT load_periods_pkey PRIMARY KEY (table_loaded, period_key)
);