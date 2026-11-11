CREATE TABLE IF NOT EXISTS control.load_runs (
    run_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at timestamptz NOT NULL,
    stopped_at timestamptz NOT NULL,
    run_type text NOT NULL CHECK (run_type IN ('full', 'incremental')),
    periods_loaded int NOT NULL DEFAULT 0,
    rows_written int NOT NULL DEFAULT 0
);
