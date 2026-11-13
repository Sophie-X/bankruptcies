# Bankruptcies NL: CBS data pipeline

A small data pipeline for Dutch bankruptcy figures from CBS (Statistics Netherlands). It loads the data into PostgreSQL in medallion layers (bronze → silver → gold) and uses an **incremental load**: on each run it fetches only the periods that are new or can still change.

> Status: work in progress (pre-gold). The scripted ingest (`scripts/ingest.py`) loads bronze incrementally and logs each run in `control.load_runs`. Silver is split into a fact and three dimensions, with the sector level mapping in `control`. The QA views read the new fact. Next: the key-matching and dimension checks in QA, then the gold layer, then the model in Python.

## Working with AI assistants

This is a learning project: I write the code myself.

- **Never edit, create or overwrite files in this repo directly. The one exception is this README:** the assistant maintains the documentation and reviews it on its own initiative every few changes.
- **Never give the full query or full script.** Explain the approach, point to the lines that need to change, and give hints or small fragments at most.

## Design principles

- **Python only fetches and loads. All transformations are in SQL.** Python reads from the CBS OData API and writes raw data to `bronze`. Silver and gold are SQL views/tables.
- **Incremental, not full refresh.** Final (`Definitief`) figures never change, so they are loaded once and then skipped. Only new or provisional periods are (re)loaded. A control table tracks this.
- **Join on codes, not on titles.** CBS sometimes rewords titles. Final periods are never reloaded, so they keep the title CBS used at the time they were loaded. A join on titles would then silently drop rows.
- **Silver is complete; gold is shaped for its use.** Silver keeps all sector levels and all period types, and only cleans, types and conforms the data. Choices made for a specific analysis (such as which sector level or period type to use) are made in gold.
- **No hardcoded IDs for analysis choices.** Choices like the sector level are stored once, as named settings in `control`, not as magic numbers in the SQL.

## Data source

| | |
|---|---|
| Provider | CBS StatLine (OData API, through the `cbsodata` package) |
| Table | `82244ENG`: bankruptcies by type of bankruptcy, sector/branch (SIC 2008) and period |
| Measure | `PronouncedBankruptcies_1`: number of pronounced bankruptcies |
| Dimensions | `TypeOfBankruptcy` (3), `SectorBranchesSIC2008` (372), `Periods` (301: months, quarters, years from 2009), plus `CategoryGroups` (116) for the sector hierarchy |
| Size | 335,916 fact rows (measured on 2026-11-06), of which 237,708 monthly |

Each period has a `Status` in the metadata: `Definitief` (final) or provisional. This status drives the incremental load.

CBS publishes 17 periods per year: 12 months, 4 quarters and 1 year. That is why 237,708 of the 335,916 rows (≈ 12/17) are monthly.

### Sector hierarchy (`CategoryGroups`)

Every sector belongs to exactly one category group. There are 116 groups (ids 0–115). They form a hierarchy that is at most two levels deep (child → root), so a sector's **root group** is "the parent of its group if there is one, otherwise the group itself".

The root groups each represent a different way of listing the sectors:

| Root group (id) | Children (ids) | Meaning | Sectors in it |
|---|---|---|---|
| Total (0) | Total (1) | all sectors | 1 (*A-U All economic activities*, in group 1) |
| **Branches 1st digit (SIC 2008)** (2) | *Main groups 1st digit* (3), *SIC unknown* (4) | the SIC sections | 20 sections A–T (group 3) + 1 *Unknown* (group 4) |
| Branches 2nd digit (SIC 2008) (5) | *Main groups 2nd digit* (6) | 2-digit branches | 85 (group 6) |
| Branches 3rd digit (SIC 2008) (7) | *Main groups 3rd digit* (8) | 3-digit branches | 265 (group 8) |
| Branches 2nd digit by 1st digit (9) | one group per section, *A Agriculture…* to *T Activities of households* (10–29) | navigation only | 0 |
| Branches 3rd digit by 2nd digit (30) | one group per 2-digit branch, *01 Agriculture* to *98 Households producing for own use* (31–115) | navigation only | 0 |

Checked on 2026-11-10 against `parentid` and against the sector lookup (`categorygroupid`): all 372 sectors are in groups 1, 3, 4, 6 and 8. The nested groups (9–29, 30–115) contain **no sectors**, so every branch is listed exactly once and no level double counts. No group is more than one level below its root.

There is no section U in this table: the sections run A–T.

No structural rule (such as "groups without a parent") picks out group 2 on its own: every listing has its own root. The level is therefore recorded as a named setting in `control` (see *Sector levels* below), not derived from the IDs.

## Architecture

```
CBS OData API (82244ENG)
        │  Python: cbsodata + pandas + SQLAlchemy
        ▼
┌───────────────┐   ┌──────────────────────────────┐
│ control       │   │ bronze                       │
│ load_periods  │   │ raw_bankruptcies  (facts)    │
│ load_runs     │   │ raw_typeofbankruptcy         │
│ sector_levels │   │ raw_sectorbranchessic2008    │
└───────────────┘   │ raw_periods                  │
                    │ raw_categorygroups           │
                    └──────────────────────────────┘
                               │  SQL
                               ▼
                    silver (views)                     ──►  qa.*  (checks)
                    fact_bankruptcies
                    dim_periods
                    dim_sectors  (+ control.sector_levels)
                    dim_typesofbankruptcies
                               │  SQL
                               ▼
                    gold  (to do)
```

### Schemas

| Schema | Contents |
|---|---|
| `control` | Load bookkeeping (`load_periods`, `load_runs`, view `load_run_durations`) and analysis settings: the sector-level mapping `sector_levels` |
| `bronze` | Raw data from CBS: table names `raw_<cbs name in lower case>`, column names lower-cased, column types picked by pandas (see *Lookups*) |
| `silver` | Cleaned, typed and conformed views (fact + dimensions), all sector levels and period types |
| `gold` | Analysis-ready models, one sector level and one period type at a time (to do) |
| `qa` | Data-quality checks on silver |

## Load logic

### Lookups: SCD Type 1

The lookup tables (`bronze.raw_periods`, `raw_sectorbranchessic2008`, `raw_typeofbankruptcy`, `raw_categorygroups`) are reloaded in full on every run, without history.

- SIC 2008 is a fixed classification: a code always means the same sector. CBS only changes the wording of titles, and no analysis needs the old wording. Type 2 history would add complexity and no value.
- The load does `TRUNCATE` + append, **not** `to_sql(if_exists='replace')`. `replace` drops the table, and that fails as soon as a silver view depends on it.
- **Column types:** before writing, `df.convert_dtypes()` gives every column the best nullable type. Without it, pandas turns an integer column with nulls (such as `parentid`) into floats (`2.0`), and Postgres stores it as `double precision`. With it, ids arrive as `bigint` (`int8`). This keeps the type CBS sends; it is not a transformation.
- **Types are fixed when a table is created.** `TRUNCATE` + append keeps the existing table and its column types, and `to_sql` never changes them. A type change in the ingest therefore only reaches Postgres after a one-time rebuild: drop the dependent silver views, drop the lookup table, run the ingest, recreate the views. (`ALTER COLUMN ... TYPE` is no shortcut: Postgres refuses it for columns that a view uses.) A fresh database gets the right types on the first run.

### Facts: incremental load with a control table

On each run:

1. Get the current status of each period from the CBS `Periods` metadata.
2. Compare it with `control.load_periods`, which holds the status each period had when it was last loaded.
3. Select a period for (re)load if one of these is true:
   - **New**: the period is not in the control table yet.
   - **Provisional**: its status at CBS is not `Definitief`.
   - **Status changed**: the status differs from the last load (for example provisional → `Definitief`).
4. Download the selected periods. On the first run (empty control table), download the full table in one call, which is faster. On later runs, download in batches of 12 periods with an OData filter (`Periods eq '…' or …`).
5. Restore the codes (`add_keys`): map each row's period, sector and type title to its key (`period_key`, `sector_key`, `type_key`) with the lookups from the same run. If any title cannot be mapped, the run stops with an error before anything is written.
6. In **one transaction**: delete the selected periods from `bronze.raw_bankruptcies` and append the new rows. Then replace their entries in `control.load_periods`, with `loaded_at` set to the current UTC time.

If any step in the transaction fails, neither the facts nor the control table change. This keeps the two in sync.

First run on 2026-11-06: 301 periods new, 3 provisional, 301 of 301 loaded (335,916 rows).

### Planned: schema-change guard

The fact table should have at least 335,916 rows. If a download returns significantly fewer, CBS has probably changed the table structure. The run must then stop with a warning instead of loading. *(Described in the notebook, not implemented yet.)*

## Silver layer

Silver is a small star schema: one fact view and three dimension views. Every view only cleans, types and conforms; nothing is filtered. All sector levels and all period types (months, quarters, years) are kept, so gold can use any of them.

> ⚠️ **Double counting.** The fact contains every sector level **and** every period type. Each bankruptcy therefore appears once per level and once per period type (month, quarter, year). Never `SUM` over it without filtering to exactly **one** sector level and **one** period type.

### `silver.fact_bankruptcies`

Keys + measure only. Source: `bronze.raw_bankruptcies`.

| Column | Source / logic |
|---|---|
| `period_key` | trimmed, e.g. `2024MM03` → `dim_periods.period_key` |
| `sector_key` | trimmed → `dim_sectors.sector_key` |
| `type_key` | trimmed → `dim_typesofbankruptcies.type_key` |
| `bankruptcies` | `pronouncedbankruptcies_1` |

Period type, date and status live in `dim_periods`, so they are derived in one place only.

**Naming:** each key has the same name in the fact and in its dimension (`period_key`, `sector_key`, `type_key`), so joins can use `USING (...)`. The values are CBS's own codes, not surrogate keys; `_key` follows CBS's `Key` column and the ingest (`add_keys`). Dimension attributes take the same prefix (`sector_title`, `type_title`, …).

### `silver.dim_periods`

One row per period. Source: `bronze.raw_periods`, left join `control.load_periods` on the trimmed key.

| Column | Source / logic |
|---|---|
| `period_key` | `key`, trimmed |
| `period_type` | characters 5–6 of the key: `MM` (month), `KW` (quarter), `JJ` (year) |
| `period_date` | first day of the period: month → that month; quarter → its first month (`quarter × 3 − 2`); year → 1 January |
| `period_status` | status from `control.load_periods` |
| `is_provisional` | `period_status <> 'Definitief'`; a period without a status counts as provisional |

### `silver.dim_sectors`

One row per sector, with its level. Source: `bronze.raw_sectorbranchessic2008`.

| Column | Source / logic |
|---|---|
| `sector_key` | `key`, trimmed |
| `sector_title` | `title` |
| `sector_categorygroupid` | `categorygroupid` |
| `level_group` | root group id from the mapping |
| `level_description` | root title from the mapping |
| `level_name` | `sbi_0` … `sbi_3` from the mapping |

Joins: sector → **LEFT JOIN** `raw_categorygroups` on its group → **LEFT JOIN** `control.sector_levels` on the root group, `COALESCE(parentid, id)`: the parent of the group, or the group itself when it has no parent. Every group that holds sectors has a parent (the total sector's group 1 sits under root 0), so in practice the join uses `parentid`; the fallback only guards against a sector placed directly in a root group. Both joins are left joins, so no sector can drop out; a sector without a level shows up with an empty `level_name` (see `qa.silver_sectors_without_level`).

### `silver.dim_typesofbankruptcies`

One row per type. Source: `bronze.raw_typeofbankruptcy`. Columns: `type_key` (trimmed `key`), `type_title`, `type_description`.

### Why fact + dimensions

The sector level is stored once, in the sector dimension. Comparing levels becomes a different filter in gold, without touching the fact. QA checks also get clear targets (fact, dimension, and the link between them). Gold joins fact and dimensions and filters to one level and one period type for each use.

*Trade-off:* the inner joins in the earlier single view (`bankruptcies_monthly`) also acted as a silent validation (unknown keys dropped out). Now that has to be an explicit QA check: fact keys that are missing from the dimensions.

### Sector levels

- **Starting level: SIC sections (1st digit, A–T, 20 sectors).** At this level each group has enough bankruptcies per month to build a model on.
- **Later:** test finer levels (2nd digit: 85 branches, 3rd digit: 265). These get sparse (many sector-months with 0 or very few bankruptcies), so they will probably need hierarchical or pooled models, where each branch borrows strength from its parent section.
- **Parent column (needed only for pooled models):** the nested category groups are empty, so the parent cannot come from `CategoryGroups`. Candidate sources: the SIC code at the start of the sector title (`011` → `01`), plus a small reference table for 2-digit branch → section (the official SBI 2008 ranges, e.g. 10–33 → C). Watch out: not every title starts with its code (*Other health care (no accommodation)* is 3-digit branch 869 but has no number).
- **Use CBS's published figures for every level; do not aggregate them yourself.** CBS suppresses or rounds some detailed cells for confidentiality, so sums of 3-digit figures would not match the official higher-level figures.

### Level mapping: `control.sector_levels`

A small table in `control` maps each root category group to a readable level name. Values: root 0 → `sbi_0` (total), root 2 → `sbi_1`, root 5 → `sbi_2`, root 7 → `sbi_3`. Roots 9 and 30 hold no sectors and are not mapped.

- **Maintained by hand, on purpose.** Which root counts as which level is an analysis decision, not something to calculate. Deriving the level from the group title (e.g. parsing "1st digit") would bring back the title dependency this design avoids.
- **Kept in version control.** `CREATE TABLE IF NOT EXISTS` + `INSERT ... ON CONFLICT (root_group_id) DO UPDATE` live in `sql/control/sector_levels.sql`. The upsert makes the file safe to run twice: a changed title or level name in the file overwrites the row, so the file stays the single source of truth. Comparable to a dbt *seed*.
- **An upsert never deletes.** A row removed from the file (or whose id changed) stays in the table until it is deleted by hand.
- **The table holds only the mapping; it joins nothing.** The silver sector dimension does the joining: sector → its category group → root group (`parentid` if set, otherwise the group itself) → **LEFT JOIN** the mapping on the root id.
- **Columns:** root group id (the key), level name, and the **expected root title** (e.g. *Branches 1st digit (SIC 2008)*). The title is not used for joining; it exists only for the sanity check below.

#### Limitation: a hand-made mapping can go out of date

The mapping is keyed on CBS's group IDs. If CBS changes the category groups, the mapping can stop matching. The design aims to make every failure **visible** rather than silent:

| CBS changes… | Effect on the mapping | Caught by |
|---|---|---|
| the wording of a title | none: the join uses IDs | the title check raises a false alarm; update the stored title |
| which group a sector belongs to | none: the join follows the group | (nothing needed) |
| adds a new root or level | its sectors get a null level | *sectors without a level* check |
| renumbers, and an old ID disappears | its sectors get a null level | *sectors without a level* check |
| renumbers, and an old ID now means something else | sectors get the **wrong** level | *root title drift* check: stored title ≠ current title |

Without the title check, the last row would be a silent error. With it, every case either has no effect or makes a QA check fail.

How likely this is: low. SIC 2008 is a fixed classification and CBS rarely renumbers within a table. The bigger risk is CBS publishing a **new table** with a newer SBI classification; that would change codes, sectors and groups at once, and the sector dimension would need rework with any approach.

## QA layer

Views in the `qa` schema check silver. Run them after every load and compare with the baseline.

Updated 2026-11-13 for the fact/dimension split. The first four views read `silver.fact_bankruptcies`; `qa.silver_sectors_without_level` and `qa.silver_duplicate_dimensions` read the dimensions. The key-matching check (fact keys vs dimensions) is still planned.

| View | Checks | Expected |
|---|---|---|
| `qa.silver_nulls` | null count per column (keys and measure), total rows, and the number of `bankruptcies = 0` | 0 nulls in all columns |
| `qa.silver_duplicates` | key combinations (type + sector + period) that occur more than once | no rows |
| `qa.silver_row_counts` | all bronze fact rows vs silver fact rows | bronze = silver (the count itself grows with every load; note it with a date when recording a baseline) |
| `qa.impossible_values` | fact rows with a negative count | no rows |
| `qa.silver_sectors_without_level` | sectors in `dim_sectors` that found no row in `control.sector_levels` (`level_group` empty) | no rows (confirmed 2026-11-13) |
| `qa.silver_duplicate_dimensions` | keys that occur more than once in a dimension (`dim_sectors`, `dim_periods`, `dim_typesofbankruptcies`), with the dimension in column `list` | no rows (confirmed 2026-11-13) |

Notes:

- `bankruptcies_zeros` includes both real zeros and blanks that were loaded as 0 (see *Known issues*). It is the upper limit on how many values were really empty.
- The fact view is 1:1 with bronze (no filter, no join), so the row-count check cannot fail today. It is a guard: it starts to matter as soon as silver filters, deduplicates or joins.
- Pattern for future checks: one view per check that **returns only the failing rows**; an empty result means the check passed. (`qa.silver_nulls` is a summary instead, which suits nulls.)
- A check that asks one question of several dimensions is **one view**: one CTE per dimension with the same columns (`dimension_key`, `occurrences`, `list`), stacked with `UNION ALL`. `list` says which dimension a failing row comes from.
- Duplicate checks count rows (`COUNT(*)`), not keys: `COUNT(column)` skips NULLs, so duplicate empty keys would be missed.

### Planned checks

- **Gaps in the grid:** no missing periods, and the same number of sector/type combinations in every period.
- **Codes that don't match:** fact keys that are missing from the dimensions (needed after the silver split).
- **Values that can't be right:** negative counts are covered by `qa.impossible_values`; still to add: a malformed `period_key` and periods in the future (both are period checks, so they fit `dim_periods`).
- **Unknown period types:** periods in `dim_periods` with an empty `period_date` (a period type other than `MM`, `KW`, `JJ`).
- **Provisional vs final:** final figures never change between loads; provisional status only in the most recent periods.
- **Totals vs parts, per level:** the sectors at one level add up to the total sector (allow for small CBS confidentiality differences).
- **Freshness:** the latest period in silver is the latest one CBS has published.
- **Sectors without a level:** sectors in the sector dimension whose root group is not in the level mapping. Should return no rows.
- **Root title drift:** mapping rows whose stored root title differs from the current title in `bronze.raw_categorygroups`. Should return no rows; a hit means CBS reworded or renumbered a group.

## Project structure

```
bankruptcies/
├── notebooks/
│   └── 01_ingest.ipynb        # exploration (first ingest prototype)
├── scripts/
│   └── ingest.py              # scripted ingest: lookups + incremental fact load + run log
├── sql/
│   ├── control/
│   │   ├── load_time.sql          # control.load_runs (run log)
│   │   ├── load_run_durations.sql # control.load_run_durations
│   │   └── sector_levels.sql      # control.sector_levels (level mapping)
│   ├── silver/
│   │   ├── fact_bankruptcies.sql        # silver.fact_bankruptcies
│   │   ├── dim_periods.sql              # silver.dim_periods
│   │   ├── dim_sectors.sql              # silver.dim_sectors
│   │   └── dim_typesofbankruptcies.sql  # silver.dim_typesofbankruptcies
│   ├── gold/
│   │   └── bankruptcies_monthly   # first draft, does not run yet
│   └── qa/
│       ├── nulls.sql              # qa.silver_nulls
│       ├── duplicates.sql         # qa.silver_duplicates
│       ├── row_counts.sql         # qa.silver_row_counts
│       ├── impossible_values.sql  # qa.impossible_values
│       ├── sectors_without_level.sql  # qa.silver_sectors_without_level
│       └── duplicate_dimensions.sql   # qa.silver_duplicate_dimensions
├── .env.example               # connection settings template
├── requirements.txt
└── README.md
```

## Setup

1. **Python environment**
   ```bash
   python -m venv .venv
   .venv\Scripts\activate        # Windows
   pip install -r requirements.txt
   ```
   Packages needed: `cbsodata`, `pandas`, `sqlalchemy`, `psycopg[binary]`, `python-dotenv`.

2. **Connection settings**: copy `.env.example` to `.env` and fill in your values. `.env` is git-ignored.
   ```
   PGHOST=localhost
   PGPORT=5432
   PGDATABASE=bankruptcies
   PGUSER=postgres
   PGPASSWORD=changeme
   ```

3. **Database**: create the database and the schemas. The ingest reads `control.load_periods` before it writes to it, so that table must exist before the first run:
   ```sql
   CREATE SCHEMA IF NOT EXISTS control;
   CREATE SCHEMA IF NOT EXISTS bronze;
   CREATE SCHEMA IF NOT EXISTS silver;
   CREATE SCHEMA IF NOT EXISTS gold;
   CREATE SCHEMA IF NOT EXISTS qa;

   CREATE TABLE IF NOT EXISTS control.load_periods (
       period_key text PRIMARY KEY,
       status     text,
       loaded_at  timestamptz
   );
   ```

4. **Create the control objects**: run the files in `sql/control/` (the run log table must exist before the first ingest).

5. **Run the ingest**: `python scripts/ingest.py`.

6. **Create the silver views** from `sql/silver/`. `control/sector_levels.sql` must have run first, because `dim_sectors` joins it. Then the QA views from `sql/qa/`.

> **Changing a view's columns:** `CREATE OR REPLACE VIEW` can add columns at the end, but cannot remove or rename them (*"cannot drop columns from view"*). Drop the view first, then create it again.

> **VS Code: run button does nothing?** `CREATE VIEW` returns no rows, so *No result found* in the results panel is normal; errors appear in the **Output** tab (channel *PostgreSQL*). If even a `SELECT` shows nothing, the extension has hung: reload the window (*Developer: Reload Window*) and check in DBeaver that earlier statements actually ran.

> **Run the SQL against the `bankruptcies` database, not the default `postgres` database.** In the VS Code PostgreSQL extension the active database is shown above the editor and in the status bar; an editor connected to `postgres` creates schemas in the wrong place or fails with "relation does not exist".

## Roadmap

- [x] Explore CBS metadata and data
- [x] Load lookups to bronze (SCD Type 1)
- [x] Incremental fact load with control table
- [x] First silver view: `bankruptcies_monthly`
- [x] Silver joins on codes instead of titles
- [x] Remove the sector-level filter from silver (all levels kept)
- [x] QA views: nulls, duplicates, row counts
- [x] Move the ingest from the notebook to `scripts/ingest.py`
- [x] Run log: `control.load_runs` (one row per run: start, stop, full/incremental, periods loaded, rows written) and the view `control.load_run_durations`, written by `ingest.py` in the same transaction as the facts
- [x] Publish to public Git repository (pre-gold version)
- [x] Split silver into fact + dimensions, with the sector level in the sector dimension and the level mapping in `control`
- [x] Lookups keep integer types (`convert_dtypes`), so `parentid` is `bigint` instead of float
- [x] Point the QA views at the new silver fact
- [ ] QA: key-matching check (fact keys vs dimensions)
- [ ] Remaining QA checks (see *Planned checks*)
- [ ] Gold layer: model-ready view at one sector level (start: SIC sections)
- [ ] Test the model at finer sector levels
- [ ] Schema-change guard (row-count check)
- [ ] Put the DDL for the schemas and the control table in `sql/`
- [ ] Fetch codes directly from the CBS OData `TypedDataSet` endpoint instead of `cbsodata.get_data`
  - *Why:* the CBS API stores and returns codes, but `cbsodata` replaces them with titles. The ingest now restores the codes at load time (`add_keys`: title → key via the lookups from the same run). This is not a transformation but undoing one, and it cannot move to silver: a title join against the current lookups would drop rows whenever CBS rewords a title, because final periods are never reloaded.
  - *Benefit:* bronze becomes truly raw (codes as CBS stores them), `add_keys` disappears, and Python only fetches and loads.
  - *To check first:* the endpoint returns data in pages, so the fetch has to follow the next-page links that `cbsodata` currently handles.
- [ ] Refinement: log failed runs in `control.load_runs` as well
  - *Why:* the run row is now inserted at the end of a successful run, inside the facts transaction. A run that crashes rolls back and leaves no trace.
  - *How:* split the logging into `start_run()` (inserts a row with `status = 'running'` and returns the `run_id`, in its own transaction) and `finish_run(run_id, ...)` (updates that row with the stop time, counts and `status = 'success'`). A crashed run stays on `'running'`.
  - *Table changes:* add a `status` column (with a `CHECK` on the allowed values) and allow `stopped_at` to be null.

## Known issues / to check

- **Empty measure values are loaded as 0, not null.** Some CBS values are empty, but they arrive in Postgres as 0. This mixes "unknown / not published" with "zero bankruptcies", and it is a transformation in Python, against the design principles. To check: where the 0 comes from (`fillna`, `astype(int)` or the insert), and what CBS shows for those cells. Fix: drop the conversion, store the column as nullable in bronze, and decide in silver or gold how to treat nulls.
- `silver.fact_bankruptcies.bankruptcies` is not cast. Its type is whatever pandas chose for the bronze column. Cast it to integer in silver so gold and QA do not each have to.
- **SIC unknown:** group 4 (*SIC unknown*) sits under the 1st-digit root, so it would count as part of the section level. Decide whether to keep it: useful for reconciling with the total, probably noise for the model.
- `sql/gold/bankruptcies_monthly` has no `.sql` extension, reads bronze directly and joins to `s` and `t`, which are never defined. Rebuild it on the silver fact and dimensions.
- An early run created a stray `qa` schema in the default `postgres` database. Drop it there (connected to `postgres`, not `bankruptcies`).
- In the notebook, the lookup-load cell uses `engine` before the *Connect to PostgreSQL* cell defines it. A clean run from top to bottom fails. (The notebook is now exploration only; the ingest runs from `scripts/ingest.py`.)