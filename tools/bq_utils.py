#!/usr/bin/env python3
"""BigQuery helper commands for the ora2bq migration skill.

Uses Application Default Credentials (gcloud auth application-default login).
Object names can be bare (`returns`), `dataset.name`, or `project.dataset.name`;
bare names resolve to the default project and dataset below.

Usage:
    python tools/bq_utils.py exists returns orders sp_log_etl_run
    python tools/bq_utils.py find orders customers          # search every dataset in the project
    python tools/bq_utils.py schema returns
    python tools/bq_utils.py apply bq/ddl/returns.sql [--dry-run]
    python tools/bq_utils.py routine-exists sp_process_returns

Exit codes: 0 = success / all present, 1 = something missing or failed.
"""

import argparse
import json
import sys
from pathlib import Path

from google.api_core.exceptions import GoogleAPIError, NotFound
from google.cloud import bigquery

DEFAULT_PROJECT = "project-5c016d48-80d5-4534-b69"
DEFAULT_DATASET = "orc_dataset"


def qualify(name, project, dataset):
    parts = name.strip("`").split(".")
    if len(parts) == 1:
        return f"{project}.{dataset}.{parts[0].lower()}"
    if len(parts) == 2:
        return f"{project}.{parts[0]}.{parts[1].lower()}"
    return ".".join(parts[:2] + [parts[2].lower()])


def lookup(client, full_name):
    """Return (kind, object) for a table/view/routine, or (None, None) if absent."""
    try:
        table = client.get_table(full_name)
        return table.table_type, table
    except NotFound:
        pass
    try:
        routine = client.get_routine(full_name)
        return routine.type_, routine
    except NotFound:
        return None, None


def cmd_exists(client, args):
    result, missing = {}, False
    for name in args.names:
        full = qualify(name, args.project, args.dataset)
        kind, _ = lookup(client, full)
        result[full] = {"exists": kind is not None, "type": kind}
        missing |= kind is None
    print(json.dumps(result, indent=2))
    return 1 if missing else 0


def cmd_find(client, args):
    """Search every dataset in the project; exit 1 if any name is missing from the target dataset."""
    index = {}
    for ds in client.list_datasets(args.project):
        for t in client.list_tables(ds.reference):
            index.setdefault(t.table_id.lower(), []).append({"dataset": ds.dataset_id, "type": t.table_type})
        for r in client.list_routines(ds.reference):
            index.setdefault(r.routine_id.lower(), []).append({"dataset": ds.dataset_id, "type": r.type_})

    result, missing = {}, False
    for name in args.names:
        name = name.strip("`").split(".")[-1].lower()
        hits = index.get(name, [])
        target = next((h for h in hits if h["dataset"] == args.dataset), None)
        result[name] = {
            "in_target": target is not None,
            "type": target["type"] if target else None,
            "other_datasets": [h for h in hits if h["dataset"] != args.dataset],
        }
        missing |= target is None
    print(json.dumps(result, indent=2))
    return 1 if missing else 0


def cmd_routine_exists(client, args):
    full = qualify(args.name, args.project, args.dataset)
    try:
        routine = client.get_routine(full)
    except NotFound:
        print(json.dumps({"routine": full, "exists": False}))
        return 1
    print(json.dumps({
        "routine": full,
        "exists": True,
        "type": routine.type_,
        "arguments": [{"name": a.name, "mode": a.mode, "type": a.data_type.type_kind if a.data_type else None}
                      for a in routine.arguments],
        "modified": routine.modified.isoformat() if routine.modified else None,
    }, indent=2))
    return 0


def field_to_dict(field):
    d = {"name": field.name, "type": field.field_type, "mode": field.mode}
    if field.precision is not None:
        d["precision"], d["scale"] = field.precision, field.scale
    if field.fields:
        d["fields"] = [field_to_dict(f) for f in field.fields]
    return d


def cmd_schema(client, args):
    full = qualify(args.name, args.project, args.dataset)
    try:
        table = client.get_table(full)
    except NotFound:
        print(f"{full} not found", file=sys.stderr)
        return 1
    print(json.dumps([field_to_dict(f) for f in table.schema], indent=2))
    return 0


def cmd_apply(client, args):
    sql = Path(args.file).read_text()
    config = bigquery.QueryJobConfig(dry_run=args.dry_run, use_legacy_sql=False)
    try:
        job = client.query(sql, job_config=config, location=args.location)
        if not args.dry_run:
            job.result()
    except GoogleAPIError as e:
        print(f"FAILED {args.file}: {e}", file=sys.stderr)
        return 1
    if args.dry_run:
        print(f"dry run OK: {args.file} ({job.total_bytes_processed or 0} bytes would be processed)")
    else:
        print(f"applied {args.file} (job {job.job_id})")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--location", default=None, help="job location (default: inferred)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("exists", help="check whether tables/views/routines exist")
    p.add_argument("names", nargs="+")
    p.set_defaults(func=cmd_exists)

    p = sub.add_parser("find", help="search all datasets in the project for tables/views/routines")
    p.add_argument("names", nargs="+")
    p.set_defaults(func=cmd_find)

    p = sub.add_parser("routine-exists", help="check that a procedure/function is deployed")
    p.add_argument("name")
    p.set_defaults(func=cmd_routine_exists)

    p = sub.add_parser("schema", help="print a table's columns as JSON")
    p.add_argument("name")
    p.set_defaults(func=cmd_schema)

    p = sub.add_parser("apply", help="run a SQL file (DDL or CREATE PROCEDURE)")
    p.add_argument("file")
    p.add_argument("--dry-run", action="store_true", help="validate only, don't execute")
    p.set_defaults(func=cmd_apply)

    args = parser.parse_args()
    client = bigquery.Client(project=args.project)
    sys.exit(args.func(client, args))


if __name__ == "__main__":
    main()
