# import packages
import cbsodata
import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import text, inspect, create_engine, URL
import os

# set constants
TABLE_ID = '82244ENG'

# set functions

## function to connect to postgreSQL
def get_engine():                                                                   
    load_dotenv()                                                                           # load env file credentials  
    url = URL.create(                                                                       # URL.create combines read env. values to build connection URL
        drivername="postgresql+psycopg",
        username=os.getenv("PGUSER"),
        password=os.getenv("PGPASSWORD"),
        host=os.getenv("PGHOST"),
        port=int(os.getenv("PGPORT")),
        database=os.getenv("PGDATABASE"),
        ) 
    return create_engine(url)                                                               # return an engine for the PostgreSQL database

## function to load in periods with incremental load behaviour & control table: ask CBS for the status of each period (metadata). Compare it with what was loaded last time, and ONLY (re)load a period if: (1) the period isn’t in your database yet, (2) data is marked provisional at CBS, or (3) Status changed since last load (for figures that move from provisional -> definitief)
def periods_to_load(engine):                                                              
    source = pd.DataFrame(cbsodata.get_meta(TABLE_ID, 'Periods'))[['Key', 'Status']]        # get CBS meta data Periods and keep only key & status columns
    source.columns = ['period_key', 'status']                                               # rename columns
    source['status'] = source['status'].fillna('').str.strip()                              # clean status column: replace missing status with '' and trim spaces
    loaded = pd.read_sql('SELECT period_key, status FROM control.load_periods', engine)     # what we loaded before: existing control table load_periods from postgreSQL database
    compare = source.merge(loaded, on='period_key', how='left',                             # left join new CBS meta data Periods with existing control table based on key = period_key
                       suffixes=('', '_loaded'), indicator=True)                            # add suffix to differentiate between existing control table data and new CBS data
    is_new         = compare['_merge'] == 'left_only'                                       # add condition: if merge is left_only, i.e. period not found in the control table = is_new
    is_provisional = compare['status'] != 'Definitief'                                      # add condition: CBS status is not 'Definitief' = provisional
    status_changed = ~is_new & (compare['status'] != compare['status_loaded'])              # if not new AND status differs from last load: status has changed. 
    to_load = compare.loc[is_new | is_provisional | status_changed, 'period_key'].tolist()  # return a list of keys that meet the conditions for reload: new, provisional, or status changed
    return to_load, source, loaded.empty                                                    # return the list of keys to load, the CBS status table (needed later for the control-table log), and True/False: is the control table empty? (= first run)

## function to download the facts data 
def fetch_periods(keys, first_run, batch_size=12):
    if first_run:                                                                           # first run: return all data, one full download
        return pd.DataFrame(cbsodata.get_data(TABLE_ID))                                    # the whole table in one call
    parts = []                                                                              # empty list to collect each batch's DataFrame
    for i in range(0, len(keys), batch_size):                                               # not first run: step through the keys 12 at a time (i = 0, 12, 24, ...)
        batch = keys[i:i + batch_size]                                                      # the next 12 keys
        flt = ' or '.join(f"Periods eq '{k}'" for k in batch)                               # build the OData filter: Periods eq '…' or Periods eq '…'
        parts.append(pd.DataFrame(cbsodata.get_data(TABLE_ID, filters=flt)))                # download this batch and add it to the list
    return pd.concat(parts, ignore_index=True)                                              # stack all batches into one DataFrame

## function to store the dimensional / meta data into the postgreSQL database: bronze.dim_
def load_lookups(engine):
    props = pd.DataFrame(cbsodata.get_meta(TABLE_ID, 'DataProperties'))                     # get the list of table properties from CBS
    dims = props.loc[props['Type'].isin(['Dimension', 'TimeDimension']), 'Key'].tolist()    # get the list of names of the dimension tables (Type = Dimension/TimeDimension)
    dims.append('CategoryGroups')                                                           # CategoryGroups isn't a dimension but we need it for the sector hierarchy
    existing = inspect(engine).get_table_names(schema='bronze')                             # get list of tables already in bronze, postgreSQL database
    lookups = {}                                                                            # get empty lookups list
    for name in dims:                                                                       # for each dimension table:
        df = pd.DataFrame(cbsodata.get_meta(TABLE_ID, name))                                # download this dimension's metadata from CBS
        df.columns = df.columns.str.lower()                                                 # adjust meta data columns to start lowercase
        table = 'dim_' + name.lower()                                                       # table names are lowercase and have prefix dim_
        with engine.begin() as conn:                                                        # open a connection + transaction. Everything in this block is committed together at the end, or rolled back on an error
            if table in existing:                                                           # if meta data table already exists in postgreSQL database: 
                conn.execute(text(f'TRUNCATE bronze.{table}'))                              # empty the existing table, keep its structure
            df.to_sql(table, conn, schema='bronze', if_exists='append', index=False)        # append new data to existing table            
        print(f'bronze.{table}: {len(df)} rows')                                            # print how many rows were loaded
        lookups[name] = df                                                                  # 
    return lookups                                                                          # 

## function to restore the source codes at load time
def add_keys(new_rows, lookups):
    new_rows.columns = new_rows.columns.str.lower()                                         # lowercase the column names of new_rows
    periods = lookups['Periods']                                                            # the Periods lookup table
    period_map = dict(zip(periods['title'], periods['key']))                                # mapping table: {'2024 March': '2024MM03', ...}
    new_rows['period_key'] = new_rows['periods'].map(period_map)                            # ApplyMap: title → key, as a new column
    sectors = lookups['SectorBranchesSIC2008']                                              # the sectors lookup table
    sector_map = dict(zip(sectors['title'], sectors['key']))                                # mapping table: {'1': '', ...}
    new_rows['sector_key'] = new_rows['sectorbranchessic2008'].map(sector_map)              # ApplyMap: title → key, as a new column
    types = lookups['TypeOfBankruptcy']                                                     # the sectors lookup table
    types_map = dict(zip(types['title'], types['key']))                                     # mapping table: {'1': '', ...}
    new_rows['type_key'] = new_rows['typeofbankruptcy'].map(types_map)                      # ApplyMap: title → key, as a new column
    missing = new_rows[['period_key', 'sector_key', 'type_key']].isna().sum()               # count unmapped (NaN) keys per key column
    if missing.any():                                                                       # for missing values: raise flag
        raise ValueError(f'Unmapped keys:\n{missing}')                                      # returns error with missing keys
    return new_rows                                                                         # otherwise, return all new rows with the new mapped keys added

## function to write facts data back into postgreSQL database
def write_facts(engine, new_rows, to_load, source, run_type, started_at):
    rows_written = len(new_rows)
    periods_loaded = len(to_load)
    with engine.begin() as conn:
        if inspect(conn).has_table('raw_bankruptcies', schema='bronze'):
            conn.execute(text('DELETE FROM bronze.raw_bankruptcies WHERE period_key = ANY(:keys)'),
                        {'keys': to_load})
        new_rows.to_sql('raw_bankruptcies', conn, schema='bronze', if_exists='append', index=False)
        conn.execute(text('DELETE FROM control.load_periods WHERE period_key = ANY(:keys)'),
                    {'keys': to_load})
        log = source[source['period_key'].isin(to_load)].assign(loaded_at=pd.Timestamp.now(tz='UTC'))
        log.to_sql('load_periods', conn, schema='control', if_exists='append', index=False)
        log_run(conn, started_at, run_type, periods_loaded, rows_written)
    print(f'bronze.raw_bankruptcies: {rows_written} rows written for {periods_loaded} periods')

def log_run(conn, started_at, run_type, periods_loaded, rows_written):
    stopped_at = pd.Timestamp.now(tz='UTC')
    conn.execute(text(
            'INSERT INTO control.load_runs (started_at, stopped_at, run_type, periods_loaded, rows_written) VALUES (:started_at, :stopped_at, :run_type, :periods_loaded, :rows_written)'),
            {'started_at': started_at, 'stopped_at': stopped_at, 'run_type': run_type, 'periods_loaded': periods_loaded, 'rows_written': rows_written}
        )

## function of main actions
def main():
    started_at = pd.Timestamp.now(tz='UTC')                                                 # record the start time of the load
    engine = get_engine()                                                                   #
    lookups = load_lookups(engine)
    to_load, source, first_run = periods_to_load(engine)                                    # fetch the periods to load
    if not to_load:
        print('Nothing to load')
        return
    run_type = 'full' if first_run else 'incremental'
    new_rows = fetch_periods(to_load, first_run)                                            # download the facts data 
    new_rows = add_keys(new_rows, lookups)                                                  #
    write_facts(engine, new_rows, to_load, source, run_type, started_at)                    # store the facts data for the given periods into the postgreSQL database: bronze.raw_bankruptcies 

# execution of code
if __name__ == "__main__":                                                                  
    main()