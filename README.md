# Bankruptcies NL: CBS data pipeline

A small data pipeline for Dutch bankruptcy figures from CBS (Statistics Netherlands). It loads the data into PostgreSQL in medallion layers (bronze → silver → gold) and uses an **incremental load**: on each run it fetches only the periods that are new or can still change.

> Status: work in progress. The scripted ingest (`scripts/ingest.py`) loads bronze incrementally and logs each run in `control.load_runs`. Silver is split into a fact and three dimensions, with the sector level mapping in `control`. The silver fact now drops impossible values. The first gold view, `gold.bankruptcies_monthly_sbi_1`, gives monthly bankruptcies per SIC section: the target for the model. QA now also checks that every fact key exists in its dimension (`qa.silver_orphaned_keys`) and whether the data is up to date (`qa.silver_freshness_check`). Two analysis views (schema `analysis`) answered the open data questions before modelling: where the zeros are, and which bankruptcy type is the total (see *Analysis findings*). The total check moved to QA (`qa.silver_total_type`), because gold relies on its answer. QA also checks that every monthly series is complete (`qa.silver_complete_grid`). The model question is defined and reviewed twice (see *Early warning model*): a warning per sector for the three months after the current one, built on bankruptcy history first and tested on held-out history from 2022 onward, plus an analysis phase with the original questions (changepoints, clustering, lead/lag). The second review (2026-11-19) tightened the evaluation: scores for the start of a rise, not only per window; no model choice made on data it is then scored on; tests that fit nested models and correlated sectors. Next: the steps in *Early warning model → Next steps*.

## Working with AI assistants

This is a learning project: I write the code myself.

- **Never edit, create or overwrite files in this repo directly. The one exception is this README:** the assistant maintains the documentation and reviews it on its own initiative every few changes.
- **Never give the full query or full script.** Explain the approach, point to the lines that need to change, and give hints or small fragments at most.

## Design principles

- **Python only fetches and loads. All transformations are in SQL.** Python reads from the CBS OData API and writes raw data to `bronze`. Silver and gold are SQL views/tables.
- **Incremental, not full refresh.** Final (`Definitief`) figures never change, so they are loaded once and then skipped. Only new or provisional periods are (re)loaded. A control table tracks this.
- **Join on codes, not on titles.** CBS sometimes rewords titles. Final periods are never reloaded, so they keep the title CBS used at the time they were loaded. A join on titles would then silently drop rows.
- **Silver is complete; gold is shaped for its use.** Silver keeps all sector levels and all period types, and only cleans, types and conforms the data. Choices made for a specific analysis (such as which sector level or period type to use) are made in gold.
- **Each layer answers one question.**

  | Layer | Question | What lives here |
  |---|---|---|
  | `bronze` | What did CBS deliver? | Raw data, as loaded |
  | `silver` | Is this data correct? | Cleaning rules, types, conformed fact and dimensions. Gold trusts silver and does not check again. |
  | `qa` | What did silver do, and does the data still match our assumptions? | Checks that **report**; they never change data |
  | `gold` | What does the analysis need to see? | Business logic only: grain, scope (sector level, period type), derived measures. No data-quality filters. |

- **Silver cleans; QA makes the cleaning visible.** Every rule in silver that drops or changes rows has a QA check that counts what it affected. Nothing is removed silently. A rule that does fire is a signal that something changed at CBS.
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
                    gold (views)
                    bankruptcies_monthly_sbi_1
```

### Schemas

| Schema | Contents |
|---|---|
| `control` | Load bookkeeping (`load_periods`, `load_runs`, view `load_run_durations`) and analysis settings: the sector-level mapping `sector_levels` |
| `bronze` | Raw data from CBS: table names `raw_<cbs name in lower case>`, column names lower-cased, column types picked by pandas (see *Lookups*) |
| `silver` | Cleaned, typed and conformed views (fact + dimensions), all sector levels and period types |
| `gold` | Analysis-ready views, one sector level and one period type at a time |
| `qa` | Data-quality checks on silver; reconciliation checks also read bronze |
| `analysis` | Exploratory views that answer one-off questions about the data before modelling. Not part of the pipeline: nothing downstream reads them |

## Load logic

### Lookups: SCD Type 1

The lookup tables (`bronze.raw_periods`, `raw_sectorbranchessic2008`, `raw_typeofbankruptcy`, `raw_categorygroups`) are reloaded in full on every run, without history.

- SIC 2008 is a fixed classification: a code always means the same sector. CBS only changes the wording of titles, and no analysis needs the old wording. Type 2 history would add complexity and no value.
- **The assumption this rests on, and its risk.** The fact stores only codes, and final periods are never reloaded. If CBS ever reused a code for a different sector, period or type, every final period loaded under the old meaning would silently join to the new one, while new and provisional periods would be correct: one sector's history stitched onto another's. Within SBI 2008 this should not happen (CBS publishes a new table for a new classification rather than reusing codes; see *SBI 2025 transition* under *Known issues*). It is not prevented, only detected: see the *code meaning drift* check under *Planned checks*. If that check ever fires for real, SCD Type 2 (or a validity period on the dimension) becomes worth its complexity.
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

Silver is a small star schema: one fact view and three dimension views. Every view only cleans, types and conforms. All sector levels and all period types (months, quarters, years) are kept, so gold can use any of them. The one filter is a data-quality rule in the fact: rows with an impossible count are dropped (see below).

> ⚠️ **Double counting.** The fact contains every sector level **and** every period type. Each bankruptcy therefore appears once per level and once per period type (month, quarter, year). Never `SUM` over it without filtering to exactly **one** sector level and **one** period type.

### `silver.fact_bankruptcies`

Keys + measure only. Source: `bronze.raw_bankruptcies`.

| Column | Source / logic |
|---|---|
| `period_key` | trimmed, e.g. `2024MM03` → `dim_periods.period_key` |
| `sector_key` | trimmed → `dim_sectors.sector_key` |
| `type_key` | trimmed → `dim_typesofbankruptcies.type_key` |
| `bankruptcies` | `pronouncedbankruptcies_1` |

**Rule: only rows with `bankruptcies >= 0` are kept.**

- Negative counts are impossible, so they are dropped here and gold does not need its own filter.
- `>= 0` also drops **nulls** (a comparison with null is never true). Today this changes nothing, because empty values arrive as 0 (see *Known issues*). Once that is fixed and nulls reach bronze, decide whether to keep dropping them or to let them through as "unknown". Dropping a row removes the month from a time series; a null keeps the row and shows it as unknown.
- **Zeros are kept on purpose.** A zero is a real observation ("no bankruptcies in this sector this month"). Dropping zeros would inflate averages per month, leave gaps in time series, break year-on-year comparisons and make "months without a bankruptcy" impossible to count. Many zeros are normal at a detailed grain: the data is sparse, not wrong.
- The rule is watched by QA: the bronze vs silver row count shows how many rows it dropped (see *QA layer*).

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
| `period_title` | `title` (the current CBS title). Added 2026-11-17 for the drift check; it is the last column because of the view rule below |

**Changing a view's columns.** `CREATE OR REPLACE VIEW` can only **add** columns **at the end**. Existing columns must keep their name, type and position; inserting a column in the middle is read as renaming the column that was there, and PostgreSQL refuses (*cannot change name of view column*). Renaming, retyping or removing a column needs `DROP VIEW … CASCADE`, which also drops every view built on it (gold, QA), so those files have to be run again in dependency order. See the rebuild script in the *Roadmap*.

Backlog: derived date attributes from `period_date` (year, quarter number, month number, a sortable label such as `2025-03`, period end date, latest-period flag), so gold and the model don't each derive them. Also the number of court session days per month (first approximation: the number of Tuesdays), which the model needs (see *Early warning model*). Also check whether gold needs both `period_status` and `is_provisional`, since one is derived from the other.

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

Updated 2026-11-13 for the fact/dimension split. `qa.silver_nulls` and `qa.silver_duplicates` read `silver.fact_bankruptcies`; `qa.silver_row_counts` compares bronze with that fact; `qa.bronze_negative_counts` reads bronze (see below); `qa.silver_sectors_without_level` and `qa.silver_duplicate_dimensions` read the dimensions.

Updated 2026-11-17: `qa.silver_dimension_meaning_drift` added (reads the bronze fact and the silver dimensions). `qa.silver_orphaned_keys` added: the key-matching check (fact keys vs dimensions), reads only silver. The null check now reads bronze, because the silver fact drops rows with an empty count, so a null check on silver could never fail for the measure. The drift check now compares with `IS DISTINCT FROM`, so an empty title on either side counts as a change. Renamed to follow the naming rule (prefix = layer read): `qa.silver_nulls` → `qa.bronze_nulls`, `qa.silver_duplicates` → `qa.silver_duplicate_facts`. `CREATE OR REPLACE` does not remove a view under its old name, so the old two were dropped in the database by hand (done 2026-11-17).

Updated 2026-11-18: `qa.silver_freshness_check` added (reads silver and `control.load_runs`). The type total check moved from `analysis` to QA as `qa.silver_total_type` (file `sql/qa/total_type.sql`): it started as a one-off question, but gold now drops the total type on the strength of its answer, so it has to keep passing after every load. `qa.silver_complete_grid` added: every sector × type series has every month (reads silver).

**Which layer a check reads.** Most checks read silver, because every control happens after cleaning. The exception is **reconciliation**: a check that explains what silver dropped or changed has to compare silver with bronze.

| View | Checks | Expected |
|---|---|---|
| `qa.bronze_nulls` | null count per column (keys and measure), total rows, and the number of zero counts, in **`bronze.raw_bankruptcies`**. Reads bronze (since 2026-11-17) because the silver rule `>= 0` also drops empty counts (`NULL >= 0` is not true), so on silver `bankruptcies_nulls` was always 0. This makes it the drop-reason check for empty counts. | 0 nulls in all columns |
| `qa.silver_duplicate_facts` | key combinations (type + sector + period) that occur more than once | no rows |
| `qa.silver_row_counts` | all bronze fact rows vs silver fact rows | bronze − silver = rows dropped by the silver rule = `bankruptcies_nulls` in `qa.bronze_nulls` + the rows in `qa.bronze_negative_counts`; today 0. The count itself grows with every load; note it with a date when recording a baseline |
| `qa.bronze_negative_counts` | **bronze** fact rows with a negative count: the rows the silver rule drops for being negative. Shows the raw keys and CBS titles, so a hit can be traced back to the source | no rows. Reads bronze because the silver fact already drops negatives, so a check on silver could never fail. |
| `qa.silver_sectors_without_level` | sectors in `dim_sectors` that found no row in `control.sector_levels` (`level_group` empty) | no rows (confirmed 2026-11-13) |
| `qa.silver_duplicate_dimensions` | keys that occur more than once in a dimension (`dim_sectors`, `dim_periods`, `dim_typesofbankruptcies`), with the dimension in column `list` | no rows (confirmed 2026-11-13) |
| `qa.silver_dimension_meaning_drift` | **code meaning drift**: per sector, period and type code, the title stored with its fact rows at load time (`bronze.raw_bankruptcies`) vs its current title in the dimension. Columns: `dimension_key`, `loaded_title`, `reference_title`, `occurrences` (fact rows affected), `list`, `first_period`, `last_period`. A reconciliation check: reads bronze, because only bronze still holds the titles at load time | no rows (confirmed 2026-11-17). A hit is a reason to look, not proof of an error: most hits will be rewording; a different meaning under the same code means the history is wrong (see *Lookups: SCD Type 1*). Sort by `occurrences` to see the biggest impact first |
| `qa.silver_orphaned_keys` | **key matching**: per type, period and sector code in `silver.fact_bankruptcies`, codes with no row in their dimension (anti join, `NOT EXISTS`). Columns: `dimension_key`, `list`, `occurrences` (fact rows affected). A key that is empty in the fact also shows up here, as a row with an empty `dimension_key`; `qa.bronze_nulls` counts the same rows | no rows. This is the check that makes the inner joins in gold safe |
| `qa.silver_total_type` | **type total vs parts**: per `sector_key` and `period_key` in `silver.fact_bankruptcies` (all levels, all period types), `A047596` minus (`A047597` + `A028820`), returning only rows where the difference `IS DISTINCT FROM 0`. A missing total or missing part shows up too (NULL is distinct from 0) | no rows (confirmed 2026-11-18). Gold relies on this: it drops `A047596` and sums the two parts. A hit means CBS changed the type breakdown (e.g. a third legal form), and gold would undercount |
| `qa.silver_complete_grid` | **complete monthly grid**: per sector × type in `silver.fact_bankruptcies` (months only, all sector levels, all types), the number of distinct months present vs the number of months between the first and last month in the whole monthly fact. Columns: `sector_key`, `type_key`, `months_present`, `total_time_span`. Returns only series where the two differ | no rows. A month without bankruptcies is a row with 0, so a gap is a missing row, not a zero. Covers series that start late, stop early or have holes; does not cover a sector × type with no monthly rows at all (see notes) |
| `qa.silver_freshness_check` | **freshness**, monthly periods only. One row with three dates: the latest month CBS lists (`silver.dim_periods`), the latest month with figures (`silver.fact_bankruptcies` joined to `dim_periods`) and the date of the last load run (`control.load_runs`). From those: `load_freshness_days` (today − last run), `fact_months_behind_today` (today − latest fact month) and `fact_vs_reference_freshness_months` (latest CBS month − latest fact month). `freshness_status` names the first problem found, most serious first: no runs / empty fact / empty reference → load date in the future → no run for more than 40 days (*loading stopped*) → CBS lists a later month than the fact (*our load is behind*) → fact later than CBS or than today (should never happen) → fact more than 2 months behind today (*CBS published nothing new*) → `OK` | one row with `freshness_status = 'OK'`; normally 1 month behind today and 0 behind CBS (confirmed 2026-11-18) |

Notes:

- `bankruptcies_zeros` includes both real zeros and blanks that were loaded as 0 (see *Known issues*). It is the upper limit on how many values were really empty.
- The fact view now filters (`>= 0`), so the row-count check matters: it is the guard on that rule. A row count alone has two weak spots: it says *how many* rows were lost, not *why*, and a dropped row plus a duplicate cancel each other out. That is why it is paired with the duplicates check and, once built, the drop-reason check.
- **Naming:** a QA view's prefix is the layer it reads (`qa.silver_…`, `qa.bronze_…`), followed by what it checks.
- Pattern for future checks: one view per check that **returns only the failing rows**; an empty result means the check passed. (`qa.bronze_nulls` is a summary instead, which suits nulls. `qa.silver_freshness_check` is a status report too: it always returns one row, and `freshness_status` says whether it passed.)
- A check that asks one question of several dimensions is **one view**: one CTE per dimension with the same columns (`dimension_key`, `occurrences`, `list`), stacked with `UNION ALL`. `list` says which dimension a failing row comes from.
- Duplicate checks count rows (`COUNT(*)`), not keys: `COUNT(column)` skips NULLs, so duplicate empty keys would be missed.
- **QA vs analysis.** A view belongs in `qa` when it tests a standing assumption with a clear pass/fail that should hold after every load; it belongs in `analysis` when it answers a question once or only describes the data (the zero profiles have no wrong answer). An analysis view moves to QA once a later layer depends on its answer, as happened with the type total check.
- **Complete grid design choices (2026-11-18):**
  - *Why it matters now:* the gold feature view will build lags with window functions over rows. A missing month would make "3 months ago" silently point at the wrong month.
  - *Months only.* Silver keeps all period types, so the check filters to `MM` itself, once, in a first CTE (`monthly`: fact joined to `dim_periods`). The span and the counts both read from that CTE, so the filter lives in one place.
  - *One span for the whole fact,* not per series. A per-series min/max would pass a series that starts late or stops early, because it would only be compared with itself.
  - *`<>`, not `<`.* With the months-only filter a count above the span cannot happen; if it ever does, the check itself is broken (e.g. the filter was edited), and `<>` shows it.
  - *Months are counted as year × 12 + month*, as in the freshness check.
  - *Inner join to `dim_periods`.* A fact period missing from the dimension would drop out and look like a gap; `qa.silver_orphaned_keys` guards that.
  - *Known limit, accepted:* the check groups the rows that exist, so a sector × type with no monthly rows at all never forms a group and is not reported. Not built on purpose: a member of a reference list does not have to occur in the facts (like a closed store that has no transactions), so checking dimensions → facts would flag legitimate cases. A series that existed and then stopped *is* caught. The case that slips through is a code that never had monthly figures, e.g. a new sector code around the SBI 2025 switch; the freshness check and a look at new dimension codes cover that for now.
- **Drift vs key matching use different patterns.** Drift compares a code that exists on both sides, so it is an `INNER JOIN` on the trimmed key with `WHERE` loaded title `IS DISTINCT FROM` current title, then `GROUP BY`. Not `<>`: with an empty title on either side `<>` returns NULL and `WHERE` drops the row, so a title that disappeared would never show up. `IS DISTINCT FROM` treats NULL as a value (empty vs empty is no change, empty vs a title is a change). Key matching looks for codes with **no** partner, so it is an anti join (`NOT EXISTS`); it needs no columns from the dimension and no titles.
- Bronze keys are not trimmed. A check that joins bronze to silver joins on `TRIM(bronze key)` and groups by the same trimmed expression it outputs.
- **Freshness design choices (2026-11-18):**
  - *Months only.* Quarters and years are not modelled; they are only useful as a cross-check against the months (see *Planned checks*). CBS also publishes them only once complete (on 2026-11-18 the latest year was 2025 and the latest quarter Q3 2026), so their normal delay is long and would need separate thresholds.
  - *Three failure modes, three comparisons.* Our load missed something: CBS's list is ahead of the fact. CBS went quiet: both agree, but the latest month is old. We stopped loading: the last run is old. Fact vs today alone cannot tell the second from the third, which is why the load date is in the check.
  - *Months are counted as year × 12 + month.* `EXTRACT(MONTH ...)` alone resets every January (January − December = −11) and makes a year-old month look current.
  - *Thresholds.* CBS publishes monthly figures about two weeks after the month ends (October 2026 on 12 November 2026), so the fact is normally 1 month behind today and 2 in the first half of each month. Stale starts at 3; 2 would raise a false alarm every month. 40 days without a run assumes a monthly ingest.
  - *The reference is CBS's list as of the last run.* A view cannot call CBS; `bronze.raw_periods` is reloaded each run. If the ingest stops, the load-age branch catches it.
  - *Inner join to `dim_periods`.* A fact period missing from `dim_periods` would drop out silently (`MAX` ignores it); `qa.silver_orphaned_keys` guards that.
- Possible future false hits in the drift check: if CBS marks provisional periods in the title (e.g. an asterisk), a period loaded as provisional and now final would show up until its next reload. Not seen on 2026-11-17.

### Planned checks

- **Gaps in the grid:** built as `qa.silver_complete_grid` (see the table above), for monthly periods.
- **Codes that don't match:** built as `qa.silver_orphaned_keys` (see the table above). An empty key in the fact (source gave nothing) shows up as a row with an empty `dimension_key`, so it is told apart from a key that is missing from the dimension (dimension load bug) by that row, not by a separate column.
- **Dropped rows by reason:** bronze rows that did not make it into the silver fact, split by reason. Negatives are covered by `qa.bronze_negative_counts`, empty counts by `bankruptcies_nulls` in `qa.bronze_nulls` (now reading bronze). Together they should explain the full row-count difference.
- **Sum reconciliation:** total `bankruptcies` in bronze (valid values only) vs silver. Catches changed values that a row count misses, such as a bad cast once the measure is cast to integer.
- **Values that can't be right:** negative counts are covered by `qa.bronze_negative_counts`; still to add: a malformed `period_key` and periods in the future (both are period checks, so they fit `dim_periods`).
- **Unknown period types:** periods in `dim_periods` with an empty `period_date` (a period type other than `MM`, `KW`, `JJ`).
- **Provisional vs final:** final figures never change between loads; provisional status only in the most recent periods.
- **Totals vs parts, per level:** the sectors at one level add up to the total sector (allow for small CBS confidentiality differences).
- **Type total vs parts:** built as `qa.silver_total_type` (moved from `analysis` and renamed, 2026-11-18; the old `analysis.total_type` was dropped by hand; see the table above).
- **Freshness:** built as `qa.silver_freshness_check` (see the table above). With the SBI 2025 transition this is the main guard: the likely failure is not a changed code but a table that stops receiving new periods (see *Known issues*).
- **Months vs quarters and years:** the monthly figures add up to the quarter and year totals CBS publishes. CBS only publishes complete quarters and years (checked 2026-11-18), so every existing quarter or year can be compared; recent provisional periods may differ slightly if the totals come from a different revision.
- **Sectors without a level:** sectors in the sector dimension whose root group is not in the level mapping. Should return no rows.
- **Root title drift:** mapping rows whose stored root title differs from the current title in `bronze.raw_categorygroups`. Should return no rows; a hit means CBS reworded or renumbered a group.
- **Code meaning drift:** built as `qa.silver_dimension_meaning_drift` (see the table above). The relationship between key matching, root title drift and this check:

  | What went wrong | Caught by |
  |---|---|
  | A fact code is not in its dimension | key matching (`qa.silver_orphaned_keys`) |
  | A sector's root group is not in the level mapping | sectors without a level |
  | A mapped root group id now means something else | root title drift |
  | A fact code now means something else than when it was loaded | code meaning drift |

  Note: the planned switch to the `TypedDataSet` endpoint (see *Roadmap*) would leave only codes in bronze, so this check would lose its source. Decide before that refactor whether to keep the titles somewhere.
- **Complete grid in gold:** covered by `qa.silver_complete_grid`. Gold is silver filtered to months, `sbi_1` and the two type parts, joined with inner joins that `qa.silver_orphaned_keys` makes safe, so a complete silver grid means a complete gold grid.

## Gold layer

Gold holds business logic only: the grain, scope choices (period type, sector level) and derived measures. Data-quality rules stay in silver; gold trusts silver.

### `gold.bankruptcies_monthly_sbi_1`

Monthly bankruptcies per SIC section. Source: `sql/gold/bankruptcies_monthly`.

| | |
|---|---|
| Grain | one row per month × sector (level `sbi_1`) × type of bankruptcy (the two parts only, not the total) |
| Joins | `silver.fact_bankruptcies` → `dim_periods`, `dim_typesofbankruptcies`, `dim_sectors`, all `INNER JOIN` |
| Filters | `period_type = 'MM'`, `level_name = 'sbi_1'` and type not `A047596` (the total): scope choices only, no data-quality filters |
| Columns | `type_key`, `type_title`, `type_description`, `sector_key`, `sector_title`, `level_name`, `period_key`, `period_type`, `period_date`, `period_status`, `is_provisional`, `bankruptcies` |

Notes:

- **Inner joins rely on QA.** A fact row with a key that is missing from a dimension drops out of gold without an error. The key-matching check (`qa.silver_orphaned_keys`) is what makes the inner joins safe.
- **Filter on the level name, not on an id.** `sbi_1` is the readable name from `control.sector_levels`, so the view follows the *no hardcoded IDs* principle.
- **The view name contains the level.** A finer level means a new view. Alternative for later: one view without the level filter, with `level_name` as a column, and the level chosen in Python as a parameter. Testing 2- and 3-digit levels then becomes a change of one argument.
- **Includes *SIC unknown*.** Group 4 sits under the 1st-digit root, so the view returns 21 sectors (A–T + *Unknown*), not 20 (confirmed 2026-11-13). See *Known issues*.
- **Keeps the two parts, drops the total (decided 2026-11-18).** `A047596` (*Total entities with/without legal pers.*) = `A047597` (*Companies and institutions*) + `A028820` (*Nat. person with sole proprietorship*) in every sector and month (confirmed 2026-11-18, see *Analysis findings*). Gold keeps the finest grain it can: the two parts stay as rows, and the total is derived by summing over `type_key`. Summing is now safe, because the total row is no longer in the view. The split by legal form stays available for the model without a second view.
- **The total is excluded by its code (`'A047596'`).** This is a hardcoded value, against the *no hardcoded IDs* principle. To fix: let the type dimension say which type is the total (for example a flag on `dim_typesofbankruptcies`, or a small mapping in `control` like `sector_levels`), and filter gold on that. See *Known issues*.
- `period_type` and `level_name` are constant in this view. They are kept so the view can later be stacked with other levels.

### Analysis findings (2026-11-18)

One-off questions answered before modelling. The queries are kept as views in schema `analysis` (`sql/analysis/`), so the reasoning stays in the repo.

**Which type is the total? (`total_type.sql`)** For every sector and period in silver, at every sector level and every period type, `A047596` minus (`A047597` + `A028820`) is 0: the query for differences (`IS DISTINCT FROM 0`) returns no rows (confirmed 2026-11-18). The view compares per `sector_key` and `period_key`, so levels and period types are never mixed, and a missing total or missing parts would also show up as a difference (NULL is distinct from 0). It first read gold at section level and months; once gold dropped the total, it was pointed at `silver.fact_bankruptcies`. Since 2026-11-18 it runs as a QA check (`qa.silver_total_type`), because gold depends on the answer staying true. So `A047596` is exactly the sum of the other two. Gold therefore keeps only the two parts, and the model's target (bankruptcies per sector and month) is their sum. The zero patterns pointed the same way before the check: a total can only be 0 when all its parts are 0, so it always has the fewest zero months (e.g. Mining: sole proprietorships 0 in all months, total = companies).

**Where are the zeros? (`analysis.zero_profile_per_sector_type`, `analysis.zero_profile_per_sector_level`)** Monthly, 214 months per series:

| Level | Series (sector × type) | Share of zero months | Series with > 50% zeros |
|---|---|---|---|
| `sbi_0` (total) | 3 | 0% | 0 |
| `sbi_1` (sections) | 63 | 30% | 19 |
| `sbi_2` | 255 | 53% | 139 |
| `sbi_3` | 795 | 73% | 604 |

- **At section level the zeros are concentrated in a few sectors**, not spread evenly: *T Activities of households* is 0 in every month for every type; *B Mining*, *O Public administration* and *D Electricity* are 60–98% zeros even for the total; and sole proprietorships are sparse in many sectors.
- **Zeros are kept.** They are real observations, and dropping sparse sectors would skew the picture. Instead they shape the method: count models (Poisson / negative binomial) rather than a plain linear model, one model across all sectors (sparse series borrow from busy ones), and an absolute error metric per sector (percentage errors break on zeros). A constant series like T adds no signal; a perfect score on it says nothing about the model.
- **The warning definition has to work for small and large sectors.** One bankruptcy already doubles the normal level of a sparse sector.
- **Finer levels are thin.** At `sbi_3` three out of four months are zero, so testing finer levels is an experiment that may score worse for that reason alone.
- **SIC unknown stays in.** Its bankruptcies are real; only the sector is unknown, and leaving them out would undercount the total. In the model it has no sector-specific indicators. Its size also depends on registration practice, so a sudden rise in its share is an early sign of classification trouble (e.g. the SBI 2025 switch): a candidate QA check later.

## Early warning model

Defined and reviewed 2026-11-18; reviewed again, independently, on 2026-11-19 (see *Review log*). Nothing is built yet: this section is the specification for the analysis, the feature view and the model in Python. It is committed before any model runs, so the git history shows that the design came before the results. `gold.bankruptcies_monthly_sbi_1` is the source of the target: bankruptcies per sector and month.

### Where this came from

The project started (2026-11-05) as a descriptive question: *which sectors' bankruptcy trends broke at the same time, and which move together?* It had three methods: changepoint detection per sector, a comparison of the break dates (shared shocks or sector-specific problems), and clustering plus lead/lag analysis (which sectors move together, and does one lead?). The results were to be checked against known events: if the method finds them without being told, that is a good sign.

The plan then grew into a forecasting model. Both stay, as phases (see *Phases*): the analysis answers the original question and feeds the model. The difference matters for testing. A changepoint method is never told where the events are, so checking it against known history is a fair test. A forecasting model that trained on an event cannot be tested on that same event; it can only be tested on events it did not see (see *Testing against known events*).

### The question

Written as a request from the person who would use the output, a sector risk analyst at a trade credit insurer:

> "Every month, when CBS publishes the bankruptcy figures, I review our exposure per sector. I want to know which sectors will probably have clearly more bankruptcies than normal in the coming months, so I can tighten limits before it happens. A warning about the month we are already in comes too late. I would rather have a few false alarms than miss a real rise, but if half the warnings are wrong I will stop reading them. And one extra bankruptcy in Mining is not news."

### Definition

| | |
|---|---|
| Decision moment | The day CBS publishes month *t* (around the middle of month *t*+1). Anything published before that moment may be used; nothing after. |
| Unit | One sector × one decision month. Starting level `sbi_1` (21 sectors, including *Unknown*; T is reported but not fitted, see *Design choices*); finer levels later. |
| Target | Total bankruptcies in the three months *t*+2 to *t*+4. Decided in mid-November 2026, that is December to February. The start and length of the window are settings, and so are the types included (default: both). |
| Normal | The sector's own bankruptcies **per court session day** over the 12 months up to *t*, skipping months in the COVID support period (see *Design choices*). The number of months and the skipping are settings per level. |
| Event (actual figures) | The window's rate per session day is at least 1.25 × normal **and** the window has at least 3 more bankruptcies than the normal rate would give. Both numbers are placeholders, set per level (see *Evaluation*). |
| Output, per sector | Expected count for the window, an 80% range, the chance of an event, a warning flag and the main driver (the feature that adds most to the predicted ratio to normal). |
| Warning | Switches on when the chance of an event reaches the upper cutoff, and off only when it drops below a lower cutoff. |
| Success | Choices between versions are made in development (see *Evaluation*). On the test period, each version is scored once against the naive baselines, with intervals instead of a significance test: does it catch the **start** of rises in time; does it rank event windows above the rest within each sector (AUROC); at the chosen cutoff, how many events does it catch while at most half of its warnings are wrong; are its chances calibrated (of all windows given about 70%, about 70% turn out to be events); and does the predicted range hold the outcome as often as it says. |

### Design choices

- **Court session days.** Courts usually pronounce bankruptcies on one fixed weekday, mostly Tuesday, so a month has four or five session days: up to 25% difference from the calendar alone, the same size as the event threshold. CBS corrects the national total for this (table `83085NED`), but not the figures per sector, so this project corrects them itself. Session days are known in advance, so using them is no leakage. In a count model they are part of the exposure (offset). First approximation: the number of Tuesdays in the month, minus public holidays. **Check it against CBS's own correction instead of assuming it:** silver holds the uncorrected national total (`sbi_0`) and `83085NED` the corrected one, so their ratio per month is the correction CBS applies. Use the type in `83085NED` that matches this table's population (the table also covers natural persons). If the Tuesday count follows the ratio, it is confirmed; if not, the ratio shows the factor to use.
- **Forecast the count, derive the warning.** One count model (Poisson or negative binomial, all sectors together) gives a full distribution per sector and window. The expected count, the range and the chance of an event are all read from that distribution, so the warning rule can change without retraining. Monte Carlo simulation is not needed for this; it becomes useful only for questions the distribution cannot answer directly (several sectors at once, a total over a portfolio). Scenario analysis ("what if confidence drops like in 2009?") is a different question, possible once the model has indicators.
- **Scale-free features, the normal in the offset.** Sectors differ in size by a factor of a hundred or more (Trade against Mining). In one pooled log-link model, a shared coefficient on a raw count would mean something different in every sector. So:
  - The offset is log(session days in the window) + log(normal rate per session day). The model then predicts the window **as a multiple of normal**, which is exactly what the event definition tests.
  - History enters as ratios, not counts: for example the log of the last three months' rate over the normal.
  - A small constant (a setting) keeps zeros and a zero normal finite.
  - No sector intercepts at first. They are added, with shrinkage, only if calibration per sector shows a need. Pooling works through the shared coefficients: that is how sparse sectors borrow from busy ones.
- **All-zero series are not fitted.** T (*Activities of households*) is 0 in every month, so its sector effect has no finite estimate and the fit does not converge. The rule is general, not a hardcoded sector: a series with no bankruptcies in the training data is not fitted, is predicted as 0, never warns, and is reported separately. Finer levels will have more such series.
- **Dispersion per size group.** The chance of an event is read from the tail of the distribution. A negative binomial with one dispersion for all sectors gets the tails wrong for sectors of very different size. Sectors are grouped by the size of their normal (the group boundaries are a setting, set on development data), with one dispersion per group, or one fit per group if the library allows only one dispersion. Calibration is checked per group.
- **A direct comparator.** A logistic regression on the event itself, with the same features and rows, is scored like the other versions. If it beats the chances derived from the count model on the Brier score, the count model's tail is wrong.
- **A three-month window, not one month.** At `sbi_3` three out of four months are 0, so a single unusual month is mostly noise. One definition for every level keeps the levels comparable, and a quarter lines up with the quarterly business survey. The window starts after the current month, because a warning for the month already under way is not early.
- **Relative and absolute threshold.** The relative part works for large sectors; the absolute minimum stops 0 → 1 from counting as an event in small ones.
- **Normal is recent, not long-run.** A warning means "worse than the last 12 months". During a long high plateau, warnings stop once the plateau is the new normal. That is intended: an early warning reports change.
- **The COVID low is not normal.** With a plain rolling normal, the 2022 normal would rest on the 2021 record low. The rebound to pre-COVID levels would then count as an event in almost every sector: an easy catch for momentum and for the flag ending, which would flatter the main test case. By default the normal therefore skips flagged months: in early 2022 it reaches back to before March 2020. The plain rolling normal is a robustness check, and the first half of 2022 is reported separately.
- **Stable warnings.** A warning that switches on and off every month gets ignored. With two cutoffs (on at the upper one, off below the lower one) a warning stays on until the chance has clearly dropped.
- **Both types by default, companies only as a variant.** A credit insurer is mainly exposed to companies, less to sole proprietorships. Gold keeps the two types apart, so the types in the target are a setting. The companies-only run is one of the robustness checks.
- **COVID support flag.** CBS links the record low of 2021 to government support, while confidence collapsed in 2020 (producer confidence reached its all-time low in April 2020). Without a flag, a model with confidence as a feature learns the wrong sign. The period stays in the data, with a flag; its start and end dates are a setting in `control`, maintained by hand. **The flag only uses what was known at the decision moment:** the feature is "support in force at *t*". An end date announced later, or the flag over the target window, is not used, because the analyst could not have known it.
- **Settings, not constants.** Window start and length, the types in the target, months in the normal and whether it skips flagged months, the smoothing constant for zeros, event thresholds (per level), size-group boundaries, the two warning cutoffs and the share of wrong warnings allowed, the episode gap, the COVID dates, the bootstrap block length and the start of the test period are named settings in `control`, like `sector_levels`. Changing a level or a horizon is then a change of one value.
- **Known limitation: the history is final, the present is provisional.** The incremental load overwrites provisional figures, so the training history only holds final values, while at the decision moment the latest months are provisional. Indicators are revised too: in February 2026 CBS revised all seasonally adjusted producer confidence figures before January 2026 once. The model is trained on figures the analyst did not have at the time. The first plan (2026-11-06) was to keep dated snapshots of every download for this reason. Planned instead: save provisional figures as they arrive, from now on (see *Roadmap*). That builds a real record of revisions and keeps the live test clean.

### Phases

1. **Analysis: the original question.** Changepoints per sector, a comparison of break dates, clustering and lead/lag between sectors. It has two uses:
   - *Descriptive, on all data:* does the method find the known events without being told? Where it disagrees, explaining why is the interesting part.
   - *Input for the model:* leading sectors become candidate features (if construction leads trade, construction's past counts go into trade's row); clusters become groups for pooled models at finer levels; detected breaks are an independent check of the event definition (do events cluster around the breaks?).
   - **Selection happens inside the walk-forward.** A selection made once on 2009–2021 would have seen the development outcomes it is then scored on. So at each yearly refit, leading sectors and clusters are chosen again from the data known at that moment only.
   - **Correct for multiple testing.** With 20 sectors (T excluded) there are 380 ordered pairs, each at several lags. At a 5% level, about 20 pairs look like leaders by chance alone. Leading sectors are selected with a false discovery rate correction (Benjamini–Hochberg).
2. **v1: bankruptcy history and calendar only.** Recent rates as ratios to the normal, the trend, session days (offset), month of year (if seasonality remains after the session-day correction in 2009–2021), the COVID flag and the sector's size group. No leading sectors yet.
3. **v1b: v1 + leading sectors** from phase 1. Kept only if it beats v1.
4. **v2: the better of v1 and v1b + leading indicators** (producer confidence, business survey). Kept only if it beats it (see *Evaluation*).
5. **Finer levels** (`sbi_2`, `sbi_3`), with the best version.
6. **Optional: national long history** (see *Designed for later*): the only way to test against 2008.

Each version also gets a logistic comparator with the same features (see *Design choices*).

**What to expect from v1.** On its own history, v1 mostly detects momentum: "it is rising, so it will keep rising". On the window scores it may barely beat the baseline "warn if the latest window was already an event". The episode scores show the difference that matters: that baseline cannot warn at the start of a rise (see *Evaluation*). An honest result either way: the value an analyst would pay for has to come from leading sectors and from v2.

### Evaluation

Every score comes from predictions on data the model did not train on, in time order. Never a random split.

| Period | Target windows | Used for |
|---|---|---|
| Training | everything known at the decision moment | fitting the model |
| Development | windows that end in 2012–2021 | every choice: features (including seasonality and leading sectors), settings, warning cutoffs, v1 vs v1b vs v2 |
| Test | windows that start in January 2022 or later | the final score, once per version, after all choices are fixed |

- **Walk-forward in development.** For each decision month, train on what was known then and predict the next window; then move one month on. To keep it cheap, retrain once a year and use that model for the 12 decision months that follow. The first models are thin: in early 2012 they train on about 18 months.
- **The refit continues through the test period.** Each year the model is refitted on what is known by then, with every setting frozen. Refitting on new data is how the model would run live; changing a setting is not.
- **Gap between training and prediction.** A row's answer is only complete 4 months after its decision month (the window ends at *t*+4). A model used at decision month *T* trains only on rows with decision month *T*−4 or earlier. Without this gap the model trains on bankruptcies that were not known yet.
- **Why these periods.** Development holds the end of the euro-crisis rise (peak in 2013), the long decline after it and the COVID low. Test holds the 2022–2024 rise, the 2024 high and the 2025 decline. The main event in this data is therefore a clean test. A split at 2024 was considered first; it would put the 2022–2023 rise in development, where settings are tuned on it. Windows that start in 2021 and end in 2022 belong to neither set: a natural buffer between the two.
- **Analyses that feed a choice use 2009–2021 only.** This includes the seasonality analysis and the selection of leading sectors (inside the walk-forward, see *Phases*). Session days are calendar facts known in advance, so their check may use all data.
- **Event thresholds are part of the question, not of the model.** They are set once on 2009–2021 (aiming at a similar share of events per level, around 10–15%), then frozen, and are the same for every version and baseline. The test period is never used to set them.
- **Fair comparison.** v1, v1b, v2, the comparator and the baselines are scored on the same rows, the same events and the same months. If an indicator starts later or has gaps, every version is restricted to the rows the indicator covers.
- **Cutoffs from the analyst's limit.** Per version, in development, the upper cutoff is the one that catches the most events while at most half of the warnings are wrong (the share is a setting). Each version is also reported at the same number of warnings, so that a difference is not just a different cutoff.
- **Baselines.** Same window last year; the normal level (no change); "warn if the latest window was already an event".
- **Episodes: the start of a rise.** Neighbouring windows overlap and the normal moves slowly, so once a rise starts, several windows in a row are events, and "it is already rising" catches them for free. The analyst pays for the start. An **episode** is a run of event windows (by decision month) after at least 4 windows without an event (the gap is a setting). With a gap of 4, the latest complete window at the start of an episode is never an event itself. An episode is **caught** if the warning is on at the decision month of its first event window; the **lead time** is how many months the warning had been on by then (0 = just in time). The target window starts two months after the decision month, so a warning at that month is still early.
- **Scores.** T (always 0) is reported separately: a perfect score there says nothing.

  | What | Score |
  |---|---|
  | Start of a rise | Share of episodes caught; lead time |
  | Warnings, all cutoffs | AUROC, pooled and within sector; area under the precision–recall curve |
  | Warnings, chosen cutoff | Share of real events caught; share of warnings that were wrong |
  | Chances | Brier score, and a calibration table (stated chance vs the share that came true), overall and per size group |
  | Count distribution | Log score of the window count; share of outcomes inside the 80% range (should be about 80%); mean absolute error per sector of the predicted median |

  - *AUROC* is the chance that a window with an event gets a higher chance than a window without one. It is standard in early-warning research, because it does not depend on the cutoff. Pooled over sectors, it also rewards knowing *which* sectors have events more often. The analyst's question is *when*, so the main AUROC is the one **within each sector**, averaged over the sectors that have both events and non-events in the period.
  - *Precision–recall:* events are only 10–15% of windows. AUROC can look good while most warnings are wrong; the precision–recall curve shows the share of warnings that is right.
  - *Count distribution:* the range and the chances are all read from the distribution, so the whole distribution is scored, not only its mean. The error per sector uses the median, because the median is the point forecast that minimises absolute error.
- **Is a difference real? In development.** Choices are made in development, so the formal test runs there. Versions are compared on their Brier score per window.
  - Each version adds features to the one before (v1b and v2 contain v1). For such *nested* models the plain Diebold–Mariano test finds differences too rarely; the Clark–West adjustment corrects this. Non-nested comparisons (count model vs logistic comparator, a model vs a baseline) use the plain Diebold–Mariano test.
  - Neighbouring decision months share two of their three target months, so their errors move together: ten years of development hold only about 40 independent windows per sector. The test therefore uses a variance that allows for overlapping forecasts (HAC), with the small-sample correction of Harvey, Leybourne & Newbold.
  - Sectors also move together: in a given month, the errors of different sectors are not independent. So the test runs on one number per decision month (the loss difference averaged over sectors), and the HAC variance then covers both effects.
  - A version only counts as better if the test says so **and** it is better in most years and most sectors.
- **The test period: intervals, not significance.** The test holds about one cycle (the 2022 rebound, the 2024 high, the 2025 decline): about 19 non-overlapping windows per sector, and sectors that move together. A significance test there has little power, so a difference that is not significant is expected, not a failure. Test scores are reported with **block-bootstrap intervals**: resample blocks of consecutive decision months (block length a setting, around 12 months), all sectors together, so both the overlap and the co-movement are in the interval.
- **Robustness checks.** Do the conclusions hold with other event thresholds (1.15 and 1.4 instead of 1.25), another window length, the plain rolling normal (not skipping the COVID months), without the COVID years, without *Unknown*, and with companies only? They run in development, where they can still change a choice. On the test period they are reported and change nothing. A result that only holds for one setting is not a result.
- **The test is used once.** Changing anything after seeing test scores turns the test into development. The test period is not fully blind (its course is already known), so what keeps it honest is changing nothing after looking.
- **Later: a live test.** Every month the incremental load brings a period no model has seen. Storing each month's predictions and scoring them when the figures arrive gives a test that is truly out of sample.

### Testing against known events

| Event | Period | Where | What it can show |
|---|---|---|---|
| Financial crisis | 2008–2009 | not in the sector data (it starts January 2009) | Only with the national long history (see *Designed for later*) |
| Euro crisis | rise 2011–2013, peak 2013 | development | Out-of-sample predictions, but settings are tuned on this period, and the first models train on little data |
| COVID support | 2020–2021 | development | False alarms, not a missed rise: the cause was policy, which no model on this data can foresee |
| End of support, energy crisis, tax repayments | rise 2022–2024 | **test** | The main case: would the model have warned in time, trained only on what was known before? The first half of 2022 is partly a rebound from the support period and is reported separately |
| Decline | 2025 | test | False alarms in a falling market |

Three kinds of check, each valid for something different:

- **Rediscovery** (phase 1, all data): are the known breaks found without being told?
- **Out-of-sample warning** (the model, test period): did it warn before events it did not train or tune on?
- **Long history** (national level): would this approach have seen 2008 coming?

### Designed for later

**Leading indicators (v2)**

| Indicator | Frequency | Sectors | History |
|---|---|---|---|
| Producer confidence | monthly, published near the end of the month itself | manufacturing (section C) and its sub-branches | total since 1985, sub-branches since 1994 |
| Business confidence (COEN survey) | quarterly | business sectors, without banks, insurers and pension funds | since the end of 2008 |

- **Mapping to sectors.** Each sector gets the most specific indicator available: a manufacturing sub-branch, otherwise the survey's sector, otherwise the national figure. *Unknown* and T always get the national figure. The mapping is a small table in `control`, like `sector_levels`.
- **Known from.** Each indicator gets a rule for when it is known. A quarterly value is used only from its publication date, and is then carried forward through the following months.
- **Check first.** CBS announced changes to the business survey from the Q3 2023 results, and the reports up to 2023 and from 2024 link to different tables (`82675NED`, `85612NED`). Check whether the history continues or has to be stitched together.
- **SBI 2025.** Surveys are on the CBS list of statistics that switch to SBI 2025; this bankruptcy table is not (see *Known issues*). The indicator mapping is probably where the transition shows first.

**Finer levels (`sbi_2`, `sbi_3`)**

- **One feature view for all levels,** with `level_name` as a column; the level is chosen in Python.
- **Settings per level:** months in the normal, the event thresholds and the size groups. At `sbi_3` a 12-month normal rests on a few bankruptcies, so it will need a longer normal, or borrowing from the parent section (pooled model; the clusters from phase 1 are an alternative grouping). Features as ratios to the normal keep one pooled model usable across branches of very different size.
- **The parent section column** (see *Sector levels*) is needed for pooled models and for giving branches their section's indicator. It comes before the finer levels.
- **Finer levels can only win through the bankruptcy history.** The indicators are never finer than the survey's sectors. The fair test: added up per section, does `sbi_2` beat the section model (allow for CBS's confidentiality rounding)? And does it show where inside a section a rise comes from? (For example, the 2024 rise in construction came mostly from specialised construction.)

**What a risk analyst would also want**

- **Rates, not only counts.** Is the risk per company rising, or are there just more companies? CBS publishes bankruptcies per 100,000 businesses per sector, and the number of businesses per sector. A rate target, or the number of businesses as exposure, separates the two.
- **Company size.** A count treats a one-person company and a large employer the same. CBS publishes bankruptcies by company age and number of employees.
- **Companies only:** see *Design choices*.

**National long history (the 2008 test)**

- CBS's session-day-corrected bankruptcy series (`83085NED`) starts in January 1981, at national level only; producer confidence (total) starts in 1985. A national model, walk-forward tested on 2001–2003 and 2008–2009, is the only way to ask whether this approach would have seen 2008 coming.
- Check its scope first: the table also covers private persons, so it is not the same population as `82244ENG`.

### Related work (to write)

A short section on how others build and judge early warning systems, so the choices above rest on more than this project. Starting points:

- Kaminsky, Lizondo & Reinhart (1998), *Leading indicators of currency crises*: the signals approach and the noise-to-signal ratio.
- Drehmann & Juselius (2014), *Evaluating early warning indicators of banking crises: Satisfying policy requirements*: AUROC as the score that does not depend on the cutoff.
- Diebold & Mariano (1995), *Comparing predictive accuracy*; Harvey, Leybourne & Newbold (1997) for the small-sample correction.
- Clark & McCracken (2001), *Tests of equal forecast accuracy and encompassing for nested models*: why Diebold–Mariano is too strict for nested models; Clark & West (2007), *Approximately normal tests for equal predictive accuracy in nested models*: the adjustment used here.
- Benjamini & Hochberg (1995), *Controlling the false discovery rate*: the multiple-testing correction for the lead/lag selection.
- Models of aggregate business failure rates: to find.

### Review log

**2026-11-18: first review** against the original intentions, an analyst's needs and academic standards: test period moved to 2022, analysis phase restored, evaluation extended.

**2026-11-19: second, independent review** (as a senior data scientist). All points adopted:

1. **No choice is scored on the data it was made with.** Leading sectors and clusters are selected inside the walk-forward, with a correction for multiple testing; the seasonality decision uses 2009–2021 only.
2. **Scores for the start of a rise.** Episodes and lead time next to the window scores, because overlapping windows let momentum catch the middle of a rise for free.
3. **The test period gets intervals, not a significance test.** It holds about one cycle; block-bootstrap intervals over decision months, all sectors together.
4. **Tests that fit the comparisons.** Clark–West for nested versions; the test runs on the loss difference averaged over sectors per month, so co-moving sectors are not counted as independent.
5. **Scale-free features.** The normal is in the offset, history enters as ratios; all-zero series (T) are not fitted.
6. **Calibrated tails.** Dispersion per size group, and a logistic regression on the event as a comparator.
7. **COVID.** The normal skips flagged months; the flag only uses what was known at the decision moment.
8. **Scores that match the analyst.** AUROC within sector, precision–recall, the cutoff set by "at most half of the warnings wrong", and the whole count distribution scored.
9. **Clear rules.** The refit continues through the test with settings frozen; robustness checks run in development.
10. **Order of work.** Session days checked against CBS's own correction; event share and baselines come before phase 1, and v1 without leading sectors comes first.

### Next steps

1. **Commit this README** before running any model: the specification comes first.
2. **Analysis: session days.** Do months with five Tuesdays have more bankruptcies, and how many more? Compare the Tuesday count (minus public holidays) with CBS's own correction factor: `83085NED` (corrected) against silver `sbi_0` (uncorrected).
3. **`dim_periods`: session days** (with the other derived date attributes in the backlog).
4. **Analysis: seasonality,** on 2009–2021 only. After the session-day correction, is there still a month-of-year pattern?
5. **Model settings in `control`:** see the list under *Design choices → Settings, not constants*.
6. **Analysis: event share and baselines.** With the draft thresholds, what share of sector windows in 2009–2021 is an event, per level and per sector? Adjust 1.25 and 3 until it is around 10–15%, then freeze them. Then score the three baselines on development: this sets the bar before any model is built.
7. **Gold feature view (v1).** One row per sector × decision month. History as ratios to the normal, plus the parts of the offset (session days in the window, normal rate). Every column is known at the decision moment; the target window is the only column that looks forward, so checking for leakage means checking that no other column looks past *t*. Lags are built in SQL. A complete grid is guarded by `qa.silver_complete_grid`.
8. **Model v1 in Python:** baselines first, then the count model and the logistic comparator, walk-forward over development, scored as in *Evaluation*.
9. **Phase 1 in Python:** changepoints, break dates, clustering, lead/lag. The known-events check runs on all data; the selection of leading sectors runs inside the walk-forward.
10. **v1b:** v1 + leading sectors; compare with v1.
11. **v2:** load the indicator tables and the sector mapping in `control`; compare with the better of v1 and v1b.
12. **Parent section, then finer levels.**
13. **Optional: national long history** (the 2008 test).

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
│   │   └── bankruptcies_monthly   # gold.bankruptcies_monthly_sbi_1 (no .sql extension yet)
│   ├── qa/
│   │   ├── nulls.sql              # qa.bronze_nulls
│   │   ├── duplicate_facts.sql    # qa.silver_duplicate_facts
│   │   ├── row_counts.sql         # qa.silver_row_counts
│   │   ├── negative_counts.sql    # qa.bronze_negative_counts
│   │   ├── orphaned_keys.sql      # qa.silver_orphaned_keys
│   │   ├── freshness_check.sql    # qa.silver_freshness_check
│   │   ├── complete_grid.sql      # qa.silver_complete_grid
│   │   ├── dimension_meaning_drift.sql  # qa.silver_dimension_meaning_drift
│   │   ├── sectors_without_level.sql  # qa.silver_sectors_without_level
│   │   ├── duplicate_dimensions.sql   # qa.silver_duplicate_dimensions
│   │   └── total_type.sql         # qa.silver_total_type (moved from analysis)
│   └── analysis/                  # one-off questions before modelling (see *Analysis findings*)
│       ├── zero_profile_per_sector_type.sql   # analysis.zero_profile_per_sector_type
│       └── zero_profile_per_sector_level.sql  # analysis.zero_profile_per_sector_level
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

6. **Create the silver views** from `sql/silver/`. `control/sector_levels.sql` must have run first, because `dim_sectors` joins it. Then the QA views from `sql/qa/` and the gold views from `sql/gold/`.

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
- [x] QA on the dimensions: sectors without a level, duplicate keys
- [x] Silver fact drops impossible values (`bankruptcies >= 0`)
- [x] Gold: first view, `gold.bankruptcies_monthly_sbi_1` (monthly, SIC sections), on the silver fact and dimensions
- [x] QA: key-matching check (fact keys vs dimensions), `qa.silver_orphaned_keys`
- [x] QA: `qa.bronze_negative_counts` reads bronze, so it shows the negatives the silver rule drops
- [x] QA: drop-reason check for nulls in the measure (`qa.bronze_nulls` now reads bronze)
- [ ] QA: root title drift check (`control.sector_levels` stored title vs current CBS title)
- [x] QA: rename views to the layer they read (`qa.bronze_nulls`, `qa.silver_duplicate_facts`)
- [x] QA: code meaning drift check, `qa.silver_dimension_meaning_drift` (titles at load time in bronze vs current dimension titles); `dim_periods` got `period_title` for it
- [x] QA: freshness check (main guard for the SBI 2025 transition), `qa.silver_freshness_check`
- [x] QA: type total check moved from `analysis` to `qa` (`qa.silver_total_type`)
- [x] QA: complete monthly grid, `qa.silver_complete_grid`
- [ ] Remaining QA checks (see *Planned checks*)
- [x] Before the model: check whether CBS has announced an SBI 2025 bankruptcies table (none as of 2026-11-17; see *Known issues*)
- [x] Define the model question (2026-11-18, see *Early warning model*)
- [x] Review the definition against the original intentions, an analyst's needs and academic standards (2026-11-18): test period moved to 2022, analysis phase restored, evaluation extended
- [x] Second, independent review of the specification (2026-11-19): all points adopted (see *Early warning model → Review log*)
- [ ] Commit the specification before running any model
- [ ] Analysis: do five-Tuesday months have more bankruptcies? Check the Tuesday count against CBS's own correction (`83085NED` vs silver `sbi_0`). Is there seasonality after that correction (2009–2021 only)?
- [ ] `dim_periods`: derived date attributes, including court session days (see the backlog note)
- [ ] Model settings in `control` (see *Design choices → Settings, not constants*)
- [ ] Analysis: event share per level and sector on 2009–2021; freeze the thresholds; score the three baselines on development
- [ ] Gold feature view (v1): history as ratios to the normal + the parts of the offset, one row per sector × decision month, all levels in one view
- [ ] Model v1 in Python: baselines first, then the count model (normal in the offset, dispersion per size group) and the logistic comparator, walk-forward over development
- [ ] Evaluation: episodes and lead time, AUROC (within sector and pooled), precision–recall, Brier score and calibration, log score and range coverage, Clark–West test in development, block-bootstrap intervals on the test period, robustness checks
- [ ] Phase 1 in Python: changepoints, break dates, clustering, lead/lag (known-events check on all data; leading sectors selected inside the walk-forward, with a false discovery rate correction)
- [ ] v1b: v1 + leading sectors; compare with v1
- [ ] v2: load the indicator tables (producer confidence, business survey) + sector mapping in `control`; compare with the better of v1 and v1b
- [ ] Parent section column (for pooled models and for indicators at finer levels)
- [ ] Test the model at finer sector levels
- [ ] Save provisional figures as they arrive (a record of revisions; a cleaner live test)
- [ ] Later: store each month's predictions and score them when the figures arrive (live test)
- [ ] Later: rates per 100,000 businesses (number of businesses per sector) and company size
- [ ] Optional: national long history (`83085NED`, from 1981) to test against 2008
- [ ] Write the related-work section
- [ ] Schema-change guard (row-count check)
- [ ] Put the DDL for the schemas and the control table in `sql/`
- [ ] Rebuild script: drop and recreate all views in dependency order (silver → gold → qa) in one transaction, so a column change in a silver view (rename, type, removal) doesn't mean re-running files by hand
- [ ] Fetch codes directly from the CBS OData `TypedDataSet` endpoint instead of `cbsodata.get_data`
  - *Why:* the CBS API stores and returns codes, but `cbsodata` replaces them with titles. The ingest now restores the codes at load time (`add_keys`: title → key via the lookups from the same run). This is not a transformation but undoing one, and it cannot move to silver: a title join against the current lookups would drop rows whenever CBS rewords a title, because final periods are never reloaded.
  - *Benefit:* bronze becomes truly raw (codes as CBS stores them), `add_keys` disappears, and Python only fetches and loads.
  - *To check first:* the endpoint returns data in pages, so the fetch has to follow the next-page links that `cbsodata` currently handles.
- [ ] Refinement: log failed runs in `control.load_runs` as well
  - *Why:* the run row is now inserted at the end of a successful run, inside the facts transaction. A run that crashes rolls back and leaves no trace.
  - *How:* split the logging into `start_run()` (inserts a row with `status = 'running'` and returns the `run_id`, in its own transaction) and `finish_run(run_id, ...)` (updates that row with the stop time, counts and `status = 'success'`). A crashed run stays on `'running'`.
  - *Table changes:* add a `status` column (with a `CHECK` on the allowed values) and allow `stopped_at` to be null.

## Known issues / to check

- **SBI 2025 transition (2026–2029).** CBS is replacing SBI 2008 with SBI 2025 (aligned with the European NACE Rev. 2.1) and moves its statistics over in phases between 2026 and 2029, using both classifications in the meantime ([CBS](https://www.cbs.nl/en-gb/faq/sbi/until-when-will-sbi-2008-remain-in-use-)). Consequences for this project:
  - **Likely failure: the table stops, codes are not reused.** CBS usually publishes a new table for a new classification. `82244ENG` would then stop receiving new periods and a new table would continue under different codes. The freshness check is what notices this.
  - **Finer levels are hit hardest.** NACE Rev. 2.1 splits, merges and moves branches mostly at the 2- and 3-digit levels; the sections change less. The levels to be tested later are the ones with the least stable history.
  - **The mapping is not one-to-one.** CBS publishes a conversion table (*schakelschema SBI 2008–2025*). Where a branch is split, its historical counts cannot be divided over the new branches, so a long series across the switch may not be possible at 3-digit level. At section level it is much easier.
  - **For the model:** train on SBI 2008 history at section level; treat finer levels as an experiment on a series that may end.
  - **Checked 2026-11-17: no announcement.** The CBS news release of 12 Nov 2026 (October figures) still lists `82244NED` as its source and says nothing about SBI 2025. Bankruptcies are not in the CBS overview of which statistics switch in which year ([overzicht overgang statistieken](https://www.cbs.nl/-/media/_pdf/2024/35/overzicht-overgang-statistieken-sbi2025.pdf)); that list covers surveys, and this table is not a survey. KVK's business register switched to SBI 2025 in September 2025, so a switch for this table could come without a long lead time. The freshness check stays the guard. Re-check the monthly news release from time to time.
  - **Publication lag (for the freshness threshold):** October 2026 figures were published on 12 November 2026, so monthly figures appear roughly two weeks after the month ends. Used for the thresholds in `qa.silver_freshness_check`.

- **Empty measure values are loaded as 0, not null.** Some CBS values are empty, but they arrive in Postgres as 0. This mixes "unknown / not published" with "zero bankruptcies", and it is a transformation in Python, against the design principles. To check: where the 0 comes from (`fillna`, `astype(int)` or the insert), and what CBS shows for those cells. Fix: drop the conversion, store the column as nullable in bronze, and decide in silver or gold how to treat nulls.
- `silver.fact_bankruptcies.bankruptcies` is not cast. Its type is whatever pandas chose for the bronze column. Cast it to integer in silver so gold and QA do not each have to.
- **SIC unknown:** group 4 (*SIC unknown*) sits under the 1st-digit root, so it counts as part of the section level and is in `gold.bankruptcies_monthly_sbi_1` (21 sectors, confirmed 2026-11-13). Decided 2026-11-18: keep it, in gold and in the model (see *Analysis findings*).
- **Gold excludes the total type by hardcoded code `'A047596'`.** Move the meaning into the type dimension or `control` (see the gold view notes). `qa.silver_total_type` hardcodes the same three codes; it should read the same flag or mapping once that exists.
- `sql/gold/bankruptcies_monthly` has no `.sql` extension, and the file name differs from the view it creates (`gold.bankruptcies_monthly_sbi_1`).
- An early run created a stray `qa` schema in the default `postgres` database. Drop it there (connected to `postgres`, not `bankruptcies`).
- In the notebook, the lookup-load cell uses `engine` before the *Connect to PostgreSQL* cell defines it. A clean run from top to bottom fails. (The notebook is now exploration only; the ingest runs from `scripts/ingest.py`.)
