---
name: ora2bq-migrate
description: Migrate one Oracle stored procedure to BigQuery end to end - create missing dependency objects in BigQuery, convert and deploy the procedure, open a PR and wait for merge, then generate and deploy a daily Airflow DAG that calls it. Use when the user runs /ora2bq-migrate <procedure_name> or asks to migrate/convert an Oracle procedure from procedures/ to BigQuery.
argument-hint: <procedure_name> [schedule]
disable-model-invocation: true
---

# Oracle → BigQuery procedure migration

Migrate **one** procedure per run: `$ARGUMENTS`
(first word = procedure name, e.g. `sp_process_returns`; optional rest = DAG schedule).

Run the phases strictly in order. Do not start a phase until the previous phase's
**success check** passes. If a check fails, stop, fix, and re-check. Never skip ahead.

## Fixed settings

| Setting | Value |
|---|---|
| Repo root | `/Users/chiragtagadiya/Documents/ora2bq` |
| GitHub repo | `cr21/ora2bq` (base branch `main`) |
| Oracle connection | `config.json` (never print, commit, or log the password) |
| BigQuery project | `project-5c016d48-80d5-4534-b69` |
| BigQuery dataset | `orc_dataset` |
| Conversion rules | `conversion_prompt.txt` - read it fully before converting anything |
| Python | `.venv/bin/python` |
| DAG environment | Cloud Composer 3 `ora2bq-composer` in `us-central1` (`infra/composer/composer.env`) |

## Repo layout

```
procedures/<proc>.procedure.sql   Oracle source (input, from download_procedures.py)
oracle/ddl/<object>.sql           Raw Oracle DDL of dependency objects (reference)
bq/ddl/<object>.sql               BigQuery DDL for dependency tables/views/sequences
bq/procedures/<proc>.sql          Converted BigQuery procedure
dags/<proc>_daily.py              Airflow DAG calling the procedure
tools/                            oracle_utils.py, bq_utils.py helper scripts
```

All object names in BigQuery are lowercase and fully qualified:
`` `project-5c016d48-80d5-4534-b69.orc_dataset.<name>` ``.

---

## Phase 0 - Preflight

1. Confirm `procedures/<proc>.procedure.sql` exists. If not, list the files in `procedures/` and ask the user which one they meant.
2. Confirm the working tree is clean (`git status --porcelain` is empty). If not, stop and ask the user - never stash or discard their changes.
3. Sync and branch:
   ```bash
   git checkout main && git pull origin main
   git checkout -b feature/<proc>-bq-conversion
   ```
   If the branch already exists, ask whether to resume it or start over.
4. Check access: `bq ls project-5c016d48-80d5-4534-b69:orc_dataset` works and `gh auth status` is logged in.

**Success check:** on `feature/<proc>-bq-conversion`, branched from an up-to-date `main`.

---

## Phase 1 - Dependencies

### 1a. Find every object the procedure uses

Read the Oracle source and list every referenced object, grouped by kind:
- tables and views it reads from (`FROM`, `JOIN`, subqueries)
- tables it writes to (`INSERT INTO`, `UPDATE`, `DELETE`, `MERGE INTO`)
- sequences (`<seq>.NEXTVAL`), `%TYPE` / `%ROWTYPE` anchors
- other procedures/functions it calls (for example `sp_log_etl_run`)

Cross-check against Oracle so nothing is missed:
```bash
.venv/bin/python tools/oracle_utils.py deps <PROC>      # ALL_DEPENDENCIES for the procedure
```
Show the user the final dependency list before creating anything.

**Called procedures/functions are dependencies too.** If the procedure calls another
routine from `procedures/` that is not yet in BigQuery, convert that routine first
(same branch, same steps), then come back.

### 1b. Check what already exists in BigQuery

```bash
.venv/bin/python tools/bq_utils.py exists <obj1> <obj2> ...
```
For objects that already exist, compare their columns with the Oracle columns. If they
differ, report the difference to the user and ask before changing anything. Never drop
or replace an existing table that contains data without explicit approval.

### 1c. Fetch Oracle metadata for the missing objects

For each missing object:
```bash
.venv/bin/python tools/oracle_utils.py ddl <OBJECT>       # DBMS_METADATA DDL → oracle/ddl/<object>.sql
.venv/bin/python tools/oracle_utils.py columns <OBJECT>   # names, types, precision, scale, nullability
```

### 1d. Convert to BigQuery DDL

Write `bq/ddl/<object>.sql` following the DDL rules in `conversion_prompt.txt`:
- Use the data type mapping table. For `NUMBER(p,s)`, use `NUMERIC(p,s)` when p ≤ 29 and s ≤ 9, otherwise `BIGNUMERIC`. Use `INT64` for `NUMBER(p,0)` with p ≤ 18 and for plain `NUMBER` used as an ID or counter.
- Map `DATE` columns that hold a time-of-day (inspect the procedure's usage) to `DATETIME` instead of `DATE`, and add a `NOTE:` comment.
- Drop storage clauses. Turn PK/FK/CHECK constraints and indexes into `-- NOTE:` comments. Keep `NOT NULL`.
- Convert views with the same function rules as procedures.
- Convert sequences to `GENERATE_UUID()` or a `MAX(id)+ROW_NUMBER()` pattern used in the procedure, and record the choice in a `NOTE:`.
- Use `CREATE TABLE IF NOT EXISTS` for tables and `CREATE OR REPLACE VIEW` for views.

Create the objects in dependency order (tables before the views on them):
```bash
.venv/bin/python tools/bq_utils.py apply bq/ddl/<object>.sql
```

**Success check:** `tools/bq_utils.py exists` reports every dependency as present.

---

## Phase 2 - Convert and deploy the procedure

1. Read `conversion_prompt.txt` and the Oracle source. Convert the procedure into
   `bq/procedures/<proc>.sql` as a single `CREATE OR REPLACE PROCEDURE` with no table DDL.
2. Use the real BigQuery column types (from `bq show --schema`) for every INSERT/UPDATE/MERGE,
   and cast explicitly where Oracle relied on implicit conversion.
3. Oracle-specific items to handle (these are not all spelled out in the prompt):
   - `SQL%ROWCOUNT` → `@@row_count` immediately after the DML
   - `PRAGMA AUTONOMOUS_TRANSACTION`, `COMMIT`, `ROLLBACK` → remove and add a `NOTE:`
   - `RAISE_APPLICATION_ERROR` → `RAISE USING MESSAGE`
   - `SQLCODE` / `SQLERRM` → `@@error.message`
   - cursor `FOR rec IN (...) LOOP` → `FOR rec IN (...) DO ... END FOR`
   - `%TYPE` parameters → explicit BigQuery types
   - `SYSDATE` → `CURRENT_DATETIME()` when the target column is DATETIME, `CURRENT_DATE()` when DATE
   - `MERGE` → BigQuery `MERGE`
   - `TRUNC(date)` → `DATE_TRUNC` / `DATETIME_TRUNC`
4. Validate before deploying:
   ```bash
   bq query --use_legacy_sql=false --dry_run < bq/procedures/<proc>.sql
   ```
   Fix every error and repeat until the dry run is clean.
5. Deploy:
   ```bash
   .venv/bin/python tools/bq_utils.py apply bq/procedures/<proc>.sql
   ```
6. Smoke test: `CALL` the procedure with representative arguments, but only after asking the user, because it writes data. Report the row counts and any errors.

**Success check (Phase 2 done):**
```bash
.venv/bin/python tools/bq_utils.py routine-exists <proc>
```
returns true. This is the user's success criterion for step 1.

### 2b. Open the PR and wait for merge

```bash
git add oracle/ddl bq/ddl bq/procedures
git commit -m "Convert <proc> to BigQuery with dependency DDL"
git push -u origin feature/<proc>-bq-conversion
gh pr create --base main --title "[<proc>] BigQuery conversion" --body "<summary: dependencies created, NOTE: items needing review, smoke test result>"
```

Wait for the user to merge it. Check `gh pr view <n> --json state,reviewDecision,mergedAt` every 60 seconds for up to **10 minutes**, using a background loop or Monitor rather than repeated manual checks.
- `MERGED` → continue to Phase 3.
- `CLOSED` without merge → stop and ask the user why.
- Still open after 10 minutes → tell the user it is still waiting and stop. Do not continue to Phase 3 without a merge.

Note: `gh` is logged in as `cr21`, the same account that owns the repo, so GitHub will not record a self-approval. A **merge** counts as approval.

---

## Phase 3 - DAG deployment

1. Ask for the schedule if it wasn't passed in `$ARGUMENTS`. Accept a cron expression (`0 2 * * *`) or a preset (`@daily`), and confirm the timezone.
2. Sync again and create a new branch: `git checkout main && git pull origin main && git checkout -b feature/<proc>-dag`.
3. Write `dags/<proc>_daily.py`:
   - `dag_id="<proc>_daily"`, the agreed schedule, `catchup=False`, `retries=2`, `retry_delay=5min`
   - a single `BigQueryInsertJobOperator` with `location="US"` running `` CALL `project-5c016d48-80d5-4534-b69.orc_dataset.<proc>`(<args>) ``
   - tags `["ora2bq", "<proc>"]`
   - for procedure parameters such as a run date, use Airflow templates (`{{ ds }}`)
4. Check that the DAG imports cleanly: `python -c "import ast; ast.parse(open('dags/<proc>_daily.py').read())"`. If Airflow is installed, also run `airflow dags list-import-errors`.
5. Commit, push, open a PR, and wait for merge as in step 2b.
6. Deploy to Cloud Composer (see `docs/composer_setup.md`). First confirm the environment is
   `RUNNING`; if it doesn't exist, tell the user and offer to run `infra/composer/setup_composer.sh`
   (it costs money and takes ~25 minutes, so ask first):
   ```bash
   source infra/composer/composer.env
   gcloud composer environments describe $ENV_NAME --location $REGION --format="value(state)"
   infra/composer/deploy_dag.sh dags/<proc>_daily.py
   ```
7. Unpause the DAG, trigger one manual run, and wait for it to finish:
   ```bash
   R="gcloud composer environments run $ENV_NAME --location $REGION"
   $R dags unpause -- <proc>_daily
   $R dags trigger -- <proc>_daily
   $R dags list-runs -- -d <proc>_daily      # repeat until the latest run is success/failed
   ```

**Success check (Phase 3 done):** the DAG appears in Airflow without import errors, is
unpaused with the agreed schedule, and the manual run finished `success`.

---

## Final report

End with a short summary:
- dependency objects created, and those that already existed
- the procedure's BigQuery routine name
- both PR links and their merge status
- the DAG id, schedule, and first run status
- every `NOTE:` item that needs manual review

## Rules

- Migrate one procedure per run. Never batch several procedures into one PR. The one exception is a called dependency routine (see 1a).
- Never commit `config.json`, `.env`, or credentials. The repo is **public**.
- Never drop, truncate, or replace existing BigQuery tables without explicit user approval.
- Never run `CALL` against BigQuery or trigger DAG runs that write data without telling the user first.
- Never force-push or push directly to `main`.
