CREATE OR REPLACE VIEW control.load_run_durations AS
SELECT 
    *, 
    (stopped_at - started_at) AS run_duration, 
    EXTRACT(EPOCH FROM stopped_at - started_at) AS run_duration_seconds
FROM control.load_runs;
