#!/usr/bin/env python3
"""Oracle helper commands for the ora2bq migration skill.

Connection details are read from config.json in the repo root.

Usage:
    python tools/oracle_utils.py deps SP_PROCESS_RETURNS [--recursive]
    python tools/oracle_utils.py ddl RETURNS [--out-dir oracle/ddl]
    python tools/oracle_utils.py columns RETURNS
    python tools/oracle_utils.py source SP_LOG_ETL_RUN

All commands accept --owner (default: the connecting user) and --config.
Output is JSON on stdout, except `ddl` and `source`, which print the SQL.
"""

import argparse
import json
import sys
from pathlib import Path

import oracledb

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = REPO_ROOT / "config.json"

# DBMS_METADATA uses underscores where the data dictionary uses spaces
METADATA_TYPES = {
    "TABLE": "TABLE",
    "VIEW": "VIEW",
    "MATERIALIZED VIEW": "MATERIALIZED_VIEW",
    "SEQUENCE": "SEQUENCE",
    "SYNONYM": "SYNONYM",
    "PROCEDURE": "PROCEDURE",
    "FUNCTION": "FUNCTION",
    "PACKAGE": "PACKAGE_SPEC",
    "PACKAGE BODY": "PACKAGE_BODY",
    "TRIGGER": "TRIGGER",
    "TYPE": "TYPE_SPEC",
    "TYPE BODY": "TYPE_BODY",
}


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    missing = [k for k in ("username", "password", "host", "port", "service_name") if k not in cfg]
    if missing:
        sys.exit(f"config file {path} is missing keys: {', '.join(missing)}")
    return cfg


def connect(cfg):
    dsn = oracledb.makedsn(cfg["host"], int(cfg["port"]), service_name=cfg["service_name"])
    return oracledb.connect(user=cfg["username"], password=cfg["password"], dsn=dsn)


def object_type(cursor, owner, name):
    # A package and its body share a name; prefer the spec
    cursor.execute(
        """
        SELECT object_type FROM all_objects
         WHERE owner = :owner AND object_name = :name
           AND object_type NOT IN ('PACKAGE BODY', 'TYPE BODY', 'INDEX', 'LOB')
        """,
        owner=owner, name=name,
    )
    row = cursor.fetchone()
    if row is None:
        sys.exit(f"object {owner}.{name} not found")
    return row[0]


def cmd_deps(cursor, args):
    """Objects referenced by NAME (ALL_DEPENDENCIES), optionally followed recursively."""
    seen, result = set(), []
    queue = [(args.owner, args.name)]
    while queue:
        owner, name = queue.pop(0)
        if (owner, name) in seen:
            continue
        seen.add((owner, name))
        cursor.execute(
            """
            SELECT DISTINCT referenced_owner, referenced_name, referenced_type
              FROM all_dependencies
             WHERE owner = :owner AND name = :name
               AND referenced_owner NOT IN ('SYS', 'PUBLIC')
             ORDER BY referenced_type, referenced_name
            """,
            owner=owner, name=name,
        )
        for ref_owner, ref_name, ref_type in cursor.fetchall():
            result.append({"referenced_by": name, "owner": ref_owner, "name": ref_name, "type": ref_type})
            if args.recursive:
                queue.append((ref_owner, ref_name))
    print(json.dumps(result, indent=2))


def cmd_columns(cursor, args):
    """Column metadata for a table or view."""
    cursor.execute(
        """
        SELECT c.column_id, c.column_name, c.data_type, c.data_length, c.char_length,
               c.data_precision, c.data_scale, c.nullable, c.data_default, cc.comments
          FROM all_tab_columns c
          LEFT JOIN all_col_comments cc
            ON cc.owner = c.owner AND cc.table_name = c.table_name AND cc.column_name = c.column_name
         WHERE c.owner = :owner AND c.table_name = :name
         ORDER BY c.column_id
        """,
        owner=args.owner, name=args.name,
    )
    cols = [d[0].lower() for d in cursor.description]
    rows = [dict(zip(cols, row)) for row in cursor.fetchall()]
    if not rows:
        sys.exit(f"no columns found for {args.owner}.{args.name}")
    for row in rows:
        if row["data_default"] is not None:
            row["data_default"] = str(row["data_default"]).strip()
    print(json.dumps(rows, indent=2))


def configure_metadata(cursor):
    # Strip physical storage details; keep constraints so they can be noted in BigQuery DDL
    cursor.execute(
        """
        BEGIN
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', TRUE);
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
        END;
        """
    )


def fetch_ddl(cursor, owner, name, obj_type):
    cursor.execute(
        "SELECT DBMS_METADATA.GET_DDL(:type, :name, :owner) FROM dual",
        type=METADATA_TYPES[obj_type], name=name, owner=owner,
    )
    return cursor.fetchone()[0].read().strip()


def fetch_dependent_ddl(cursor, owner, name, kind):
    # kind: INDEX or COMMENT; raises ORA-31608 when there are none
    try:
        cursor.execute(
            "SELECT DBMS_METADATA.GET_DEPENDENT_DDL(:kind, :name, :owner) FROM dual",
            kind=kind, name=name, owner=owner,
        )
        return cursor.fetchone()[0].read().strip()
    except oracledb.DatabaseError:
        return None


def cmd_ddl(cursor, args):
    """Oracle DDL for an object, saved to <out-dir>/<name>.<type>.sql."""
    obj_type = object_type(cursor, args.owner, args.name)
    if obj_type not in METADATA_TYPES:
        sys.exit(f"unsupported object type {obj_type} for {args.owner}.{args.name}")
    configure_metadata(cursor)
    parts = [fetch_ddl(cursor, args.owner, args.name, obj_type)]
    if obj_type == "TABLE":
        parts += filter(None, (fetch_dependent_ddl(cursor, args.owner, args.name, k) for k in ("INDEX", "COMMENT")))
    ddl = "\n\n".join(parts) + "\n"

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{args.name.lower()}.{obj_type.lower().replace(' ', '_')}.sql"
    path.write_text(ddl)
    print(ddl)
    print(f"-- saved {obj_type} {args.owner}.{args.name} -> {path}", file=sys.stderr)


def cmd_source(cursor, args):
    """PL/SQL source of a routine from ALL_SOURCE."""
    obj_type = object_type(cursor, args.owner, args.name)
    cursor.execute(
        "SELECT text FROM all_source WHERE owner = :owner AND name = :name AND type = :type ORDER BY line",
        owner=args.owner, name=args.name, type=obj_type,
    )
    print("".join(row[0] for row in cursor), end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="path to config.json")
    parser.add_argument("--owner", help="schema owner (default: the connecting user)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("deps", help="objects referenced by a procedure/view")
    p.add_argument("name")
    p.add_argument("--recursive", action="store_true", help="follow dependencies of dependencies")
    p.set_defaults(func=cmd_deps)

    p = sub.add_parser("columns", help="column metadata for a table/view")
    p.add_argument("name")
    p.set_defaults(func=cmd_columns)

    p = sub.add_parser("ddl", help="fetch and save Oracle DDL for an object")
    p.add_argument("name")
    p.add_argument("--out-dir", default=REPO_ROOT / "oracle" / "ddl", help="default: oracle/ddl")
    p.set_defaults(func=cmd_ddl)

    p = sub.add_parser("source", help="PL/SQL source of a routine")
    p.add_argument("name")
    p.set_defaults(func=cmd_source)

    args = parser.parse_args()
    cfg = load_config(args.config)
    args.owner = (args.owner or cfg["username"]).upper()
    args.name = args.name.upper()

    with connect(cfg) as conn:
        args.func(conn.cursor(), args)


if __name__ == "__main__":
    main()
