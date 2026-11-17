## Layer responsibilities

| Layer  | Question it answers                     | What lives here |
|--------|-----------------------------------------|-----------------|
| Bronze | "What did the source deliver?"          | Raw CBS data, as loaded. No changes. |
| Silver | "Is this data correct?"                 | Typing, trimming, cleaning rules, conformed dims and facts. Downstream layers trust silver without re-checking. |
| QA     | "What did silver do, and did anything break our assumptions?" | Checks that report on every silver rule. QA reports; it does not change data. |
| Gold   | "What does the business want to see?"   | Business logic only: grain, scope filters (e.g. monthly, SBI level 1), derived measures. No defensive data-quality filters. |

**Principle:** every cleaning rule in silver has a matching QA check that counts what it affected. Nothing is removed silently.

## Silver

### `silver.fact_bankruptcies`
- Source: `bronze.raw_bankruptcies`
- Keys (`period_key`, `sector_key`, `type_key`) are trimmed.
- `pronouncedbankruptcies_1` → `bankruptcies`
- **Rule:** only rows with `bankruptcies >= 0` are kept. This drops negatives (impossible values) **and NULLs**.
- **Zeros are kept on purpose.** A zero is a real observation ("no bankruptcies this month"). Removing zeros would inflate averages, create gaps in time series and break year-on-year comparisons.
- Open: confirm what a NULL means in the CBS source (not available / suppressed?). Decide whether NULLs should be dropped (current behaviour) or kept as "unknown".
- Open: cast `bankruptcies` explicitly to an integer type if bronze delivers it as text.

## QA checks (silver)

| Check | Purpose | Status |
|-------|---------|--------|
| Bronze vs silver row count | Detect rows lost between layers | Built |
| Dropped rows by reason (negative / NULL / other) | Explain *why* rows were lost, not just how many | To do |
| Uniqueness of period × sector × type in fact | Detect duplicates (also stops duplicates from hiding drops in the row count) | To do |
| Bronze vs silver sum of bankruptcies (valid values only) | Catch value changes a row count misses (e.g. bad casts) | To do |
| Orphan keys: fact keys with no match in `dim_periods` / `dim_sectors` / `dim_types` | Gold uses inner joins; this guarantees they don't silently drop rows. Also checks keys are trimmed the same way in fact and dims. | To do |
| NULL foreign keys in fact | Separate "source gave nothing" from "dim load bug" | To do |

## Gold

### `gold.bankruptcies_monthly_sbi_1`
- Grain: one row per month × SBI level 1 sector × bankruptcy type.
- Joins: `silver.fact_bankruptcies` → `dim_periods`, `dim_types`, `dim_sectors` (all `INNER JOIN`, which is safe because silver QA checks for orphan keys).
- Filters: `period_type = 'MM'` and `level_name = 'sbi_1'`. These are business scope choices only; data-quality filtering happens in silver.
- Columns: type, sector, period attributes, `period_status`, `is_provisional`, `bankruptcies`.
- Note: `period_type` and `level_name` are constant in this view; kept for now (useful if views are later unioned).
- Note: `CREATE OR REPLACE VIEW` can't rename, reorder or drop columns in PostgreSQL; use `DROP VIEW` + `CREATE VIEW` when the column list changes.

## Backlog: `dim_periods`
- Add derived date attributes from `period_date`: year, quarter number, month number, month name, sortable label (`2025-03`, `2025 Q1`), period start/end dates, latest-period flag.
- Define what `period_date` means for `YY` and `KW` rows (assumed: first day of the period).
- Check whether `period_status` and `is_provisional` are redundant.
