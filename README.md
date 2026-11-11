# Bankruptcies NL: CBS data pipeline

A small data pipeline for Dutch bankruptcy figures from CBS (Statistics Netherlands). It loads the data into PostgreSQL in medallion layers (bronze → silver → gold) and uses an **incremental load**: on each run it fetches only the periods that are new or can still change.

> Status: work in progress (pre-gold). The scripted ingest (`scripts/ingest.py`) loads bronze incrementally and logs each run in `control.load_runs`. The first silver view and the first QA views are in place. The silver redesign (fact + dimensions) and the gold layer are still to do; after that comes the model in Python.

## Working with AI assistants

This is a learning project: I write the code myself.

- **Never edit, create or overwrite files in this repo directly. The one exception is this README:** the assistant maintains the documentation and reviews it on its own initiative every few changes.
- **Never give the full query or full script.** Explain the approach, point to the lines that need to change, and give hints or small fragments at most.

## Design principles

- **Python only fetches and loads. All transformations are in SQL.** Python reads from the CBS OData API and writes raw data to `bronze`. Silver and gold are SQL views/tables.
- **Incremental, not full refresh.** Final (`Definitief`) figures never change, so they are loaded once and then skipped. Only new or provisional periods are (re)loaded. A control table tracks this.
- **Join on codes, not on titles.** CBS sometimes rewords titles. Final periods are never reloaded, so they keep the title CBS used at the time they were loaded. A join on titles would then silently drop rows.
- **Silver is complete; gold is shaped for its use.** Silver keeps all sector levels and only cleans, types and conforms the data. Choices made for a specific analysis (such as which sector level to use) are made in gold.
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
┌──────────────┐   ┌──────────────────────────────┐
│ control      │   │ bronze                       │
│ load_periods │   │ raw_bankruptcies  (facts)    │
│ load_runs    │   │ dim_typeofbankruptcy         │
└──────────────┘   │                              │
                   │ dim_sectorbranchessic2008    │
                   │ dim_periods                  │
                   │ dim_categorygroups           │
                   └──────────────────────────────┘
                              │  SQL
                              ▼
                   silver.bankruptcies_monthly (view)  ──►  qa.*  (checks)
                              │  SQL
                              ▼
                   gold  (to do)
```

### Schemas

| Schema | Contents |
|---|---|
| `control` | Load bookkeeping (`load_periods`, `load_runs`, view `load_run_durations`) and, planned, analysis settings such as the sector-level mapping |
| `bronze` | Raw data from CBS, column names lower-cased, no other changes |
| `silver` | Cleaned, typed and conformed views, all sector levels |
| `gold` | Analysis-ready models, one sector level at a time (to do) |
| `qa` | Data-quality checks on silver |

## Load logic

### Lookups: SCD Type 1

The `bronze.dim_*` tables are reloaded in full on every run, without history.

- SIC 2008 is a fixed classification: a code always means the same sector. CBS only changes the wording of titles, and no analysis needs the old wording. Type 2 history would add complexity and no value.
- The load does `TRUNCATE` + append, **not** `to_sql(if_exists='replace')`. `replace` drops the table, and that fails as soon as a silver view depends on it.

### Facts: incremental load with a control table

On each run:

1. Get the current status of each period from the CBS `Periods` metadata.
2. Compare it with `control.load_periods`, which holds the status each period had when it was last loaded.
3. Select a period for (re)load if one of these is true:
   - **New**: the period is not in the control table yet.
   - **Provisional**: its status at CBS is not `Definitief`.
   - **Status changed**: the status differs from the last load (for example provisional → `Definitief`).
4. Download the selected periods. On the first run (empty control table), download the full table in one call, which is faster. On later runs, download in batches of 12 periods with an OData filter (`Periods eq '…' or …`).
5. Map each row's period title to its `period_key` with the `Periods` lookup.
6. In **one transaction**: delete the selected periods from `bronze.raw_bankruptcies` and append the new rows. Then replace their entries in `control.load_periods`, with `loaded_at` set to the current UTC time.

If any step in the transaction fails, neither the facts nor the control table change. This keeps the two in sync.

First run on 2026-11-06: 301 periods new, 3 provisional, 301 of 301 loaded (335,916 rows).

### Planned: schema-change guard

The fact table should have at least 335,916 rows. If a download returns significantly fewer, CBS has probably changed the table structure. The run must then stop with a warning instead of loading. *(Described in the notebook, not implemented yet.)*

## Silver layer

### `silver.bankruptcies_monthly` (view, current)

Monthly bankruptcies per type and per sector, **for all sector levels**.

| Column | Source / logic |
|---|---|
| `bankruptcy_type_code` | `dim_typeofbankruptcy.key` (trimmed) |
| `bankruptcy_type` | `typeofbankruptcy` (title, from the bronze fact table) |
| `sector_code` | `dim_sectorbranchessic2008.key` (trimmed) |
| `sector_description` | `dim_sectorbranchessic2008.title` |
| `period_key` | e.g. `2024MM03` |
| `period_date` | first day of the month, built from `period_key` |
| `period_status` | status from `control.load_periods` |
| `is_provisional` | `period_status <> 'Definitief'`; a period without a status counts as provisional |
| `bankruptcies` | `pronouncedbankruptcies_1` cast to integer |

Joins (all on codes): inner joins to the type lookup, the sector lookup and `dim_categorygroups`; left join to `control.load_periods`.

Filter: only monthly periods (`period_key LIKE '____MM__'`; the fixed length also checks the format). The earlier sector filter (category group `parentid = 2`) has been **removed**: choosing a sector level is a gold decision.

> ⚠️ **Double counting.** This view contains every sector level, so each bankruptcy appears once per level. Never `SUM` over it without filtering to exactly **one** level.

Source file: [`sql/silver/bankruptcies_monthly.sql`](sql/silver/bankruptcies_monthly.sql)

### Planned redesign: fact + dimensions

Split the single wide view into a star schema, and denormalise on purpose only in gold:

- **`silver` fact:** keys + measure + period fields only (`sector_code`, `bankruptcy_type_code`, `period_key`, `period_date`, status fields, `bankruptcies`).
- **`silver` dimensions:** sector (with its **level** and parent section), type, and possibly period.
- **`gold`:** joins fact and dimensions and filters to one level for each use.

*Why:* the sector level is then stored once, in the sector dimension. Comparing levels becomes a different filter in gold, without touching the fact. QA checks also get clear targets (fact, dimension, and the link between them).

*Trade-off:* the inner joins in the current view also act as a silent validation (unknown keys drop out). After the split this has to be an explicit QA check: fact keys that are missing from the dimensions.

Order of work:

1. Sector dimension, with the root group → level mapping in `control` (which root groups contain sectors: checked, see *Sector hierarchy*).
2. Type dimension; optionally a period dimension.
3. Reduce `bankruptcies_monthly` to keys + measure + period/status fields.
4. Point the QA views at the new fact and add the key-matching check.
5. Gold: a model-ready view, joined and filtered to one level.

After step 3, the row-count and duplicates checks should give the same results as before (237,708 rows, no duplicates).

### Sector levels

- **Starting level: SIC sections (1st digit, A–T, 20 sectors).** At this level each group has enough bankruptcies per month to build a model on.
- **Later:** test finer levels (2nd digit: 85 branches, 3rd digit: 265). These get sparse (many sector-months with 0 or very few bankruptcies), so they will probably need hierarchical or pooled models, where each branch borrows strength from its parent section.
- **Parent column (needed only for pooled models):** the nested category groups are empty, so the parent cannot come from `CategoryGroups`. Candidate sources: the SIC code at the start of the sector title (`011` → `01`), plus a small reference table for 2-digit branch → section (the official SBI 2008 ranges, e.g. 10–33 → C). Watch out: not every title starts with its code (*Other health care (no accommodation)* is 3-digit branch 869 but has no number).
- **Use CBS's published figures for every level; do not aggregate them yourself.** CBS suppresses or rounds some detailed cells for confidentiality, so sums of 3-digit figures would not match the official higher-level figures.

### Level mapping (planned)

A small table in `control` maps each root category group to a readable level name. Values: root 0 → `sbi_0` (total), root 2 → `sbi_1`, root 5 → `sbi_2`, root 7 → `sbi_3`. Roots 9 and 30 hold no sectors and are not mapped.

- **Maintained by hand, on purpose.** Which root counts as which level is an analysis decision, not something to calculate. Deriving the level from the group title (e.g. parsing "1st digit") would bring back the title dependency this design avoids.
- **Kept in version control.** `CREATE TABLE` + `INSERT` live in a SQL file (planned: `sql/control/sector_levels.sql`) that is safe to run twice, so anyone can rebuild the table. Comparable to a dbt *seed*.
- **The table holds only the mapping; it joins nothing.** The silver sector dimension does the joining: sector → its category group → root group (`parentid` if set, otherwise the group itself; cast `parentid` to integer) → **LEFT JOIN** the mapping on the root id.
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

| View | Checks | Baseline (2026-11-10) |
|---|---|---|
| `qa.silver_nulls` | null count per column (keys and measure), total rows, and the number of `bankruptcies = 0` | 0 nulls expected in all columns |
| `qa.silver_duplicates` | key combinations (type + sector + period) that occur more than once | no rows |
| `qa.silver_row_counts` | bronze monthly rows vs silver rows | 237,708 = 237,708 |

Notes:

- `bankruptcies_zeros` includes both real zeros and blanks that were loaded as 0 (see *Known issues*). It is the upper limit on how many values were really empty.
- The row-count check repeats silver's filter on the bronze side (monthly periods only). If silver ever filters on purpose again, the bronze side must use the same filter.
- Pattern for future checks: one view per check that **returns only the failing rows**; an empty result means the check passed. (`qa.silver_nulls` is a summary instead, which suits nulls.)

### Planned checks

- **Gaps in the grid:** no missing periods, and the same number of sector/type combinations in every period.
- **Codes that don't match:** fact keys that are missing from the dimensions (needed after the silver split).
- **Values that can't be right:** negative counts, a malformed `period_key`, periods in the future.
- **Provisional vs final:** final figures never change between loads; provisional status only in the most recent periods.
- **Totals vs parts, per level:** the sectors at one level add up to the total sector (allow for small CBS confidentiality differences).
- **Freshness:** the latest period in silver is the latest one CBS has published.
- **Sectors without a level:** sectors in the sector dimension whose root group is not in the level mapping. Should return no rows.
- **Root title drift:** mapping rows whose stored root title differs from the current title in `dim_categorygroups`. Should return no rows; a hit means CBS reworded or renumbered a group.

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
│   │   └── sector_levels.sql      # control.sector_levels (level mapping, in progress)
│   ├── silver/
│   │   └── bankruptcies_monthly.sql
│   └── qa/
│       ├── nulls.sql          # qa.silver_nulls
│       ├── duplicates.sql     # qa.silver_duplicates
│       └── row_counts.sql     # qa.silver_row_counts
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

5. **Run the ingest**: `python scripts/ingest.py`. Then create the silver view(s) from `sql/silver/` and the QA views from `sql/qa/`.

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
- [ ] Split silver into fact + dimensions, with the sector level in the sector dimension and the level mapping in `control`
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
- `bronze.dim_categorygroups.parentid` is stored as a float (`2.0`, `30.0`) because pandas turns an integer column with nulls into floats. Cast it to integer in silver (or load it as a nullable integer) before joining it to `id`.
- **SIC unknown:** group 4 (*SIC unknown*) sits under the 1st-digit root, so it would count as part of the section level. Decide whether to keep it: useful for reconciling with the total, probably noise for the model.
- `silver.bankruptcies_monthly` still joins `dim_categorygroups` without using it. The inner join can still drop sectors without a (matching) category group. It will be used for the level once the sector dimension exists.
- `bankruptcy_type` comes from the bronze fact table, while `sector_description` comes from the lookup. Use the lookup for both (`dim_typeofbankruptcy.title`).
- `qa.silver_nulls` was first written against `silver.raw_bankruptcies`. Make sure all QA views read the same silver object.
- An early run created a stray `qa` schema in the default `postgres` database. Drop it there (connected to `postgres`, not `bankruptcies`).
- In the notebook, the lookup-load cell uses `engine` before the *Connect to PostgreSQL* cell defines it. A clean run from top to bottom fails. (The notebook is now exploration only; the ingest runs from `scripts/ingest.py`.)
