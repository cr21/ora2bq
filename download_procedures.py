#!/usr/bin/env python3
"""Download Oracle stored procedure source code to local .sql files.

Connection details are read from config.json:
    {"username": ..., "password": ..., "host": ..., "port": ..., "service_name": ...}

Usage:
    python download_procedures.py                         # procedures in the user's schema
    python download_procedures.py --owner RETAIL          # procedures in another schema
    python download_procedures.py --types PROCEDURE FUNCTION PACKAGE "PACKAGE BODY"
    python download_procedures.py --name 'GET_%'          # filter by name (LIKE pattern)
"""

import argparse
import json
import sys
from pathlib import Path

import oracledb

DEFAULT_CONFIG = Path(__file__).resolve().parent / "config.json"

# DBMS_METADATA uses underscores where the data dictionary uses spaces
METADATA_TYPES = {
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


def list_objects(cursor, owner, types, name_pattern):
    binds = {"owner": owner, "name_pattern": name_pattern}
    type_binds = []
    for i, t in enumerate(types):
        binds[f"t{i}"] = t
        type_binds.append(f":t{i}")
    cursor.execute(
        f"""
        SELECT object_name, object_type, status
          FROM all_objects
         WHERE owner = :owner
           AND object_type IN ({", ".join(type_binds)})
           AND object_name LIKE :name_pattern
         ORDER BY object_type, object_name
        """,
        binds,
    )
    return cursor.fetchall()


def configure_metadata(cursor):
    # Make the generated DDL clean and re-runnable
    cursor.execute(
        """
        BEGIN
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', TRUE);
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
        END;
        """
    )


def get_ddl(cursor, owner, name, object_type):
    try:
        cursor.execute(
            "SELECT DBMS_METADATA.GET_DDL(:type, :name, :owner) FROM dual",
            type=METADATA_TYPES[object_type], name=name, owner=owner,
        )
        lob = cursor.fetchone()[0]
        return lob.read() if lob is not None else None
    except oracledb.DatabaseError:
        # Fall back to ALL_SOURCE (e.g. when lacking SELECT_CATALOG_ROLE for other schemas)
        cursor.execute(
            """
            SELECT text FROM all_source
             WHERE owner = :owner AND name = :name AND type = :type
             ORDER BY line
            """,
            owner=owner, name=name, type=object_type,
        )
        lines = [row[0] for row in cursor]
        if not lines:
            return None
        return "CREATE OR REPLACE " + "".join(lines).rstrip() + "\n/\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="path to config.json")
    parser.add_argument("--owner", help="schema to export (default: the connecting user)")
    parser.add_argument("--types", nargs="+", default=["PROCEDURE"], type=str.upper,
                        choices=sorted(METADATA_TYPES), help="object types to export (default: PROCEDURE)")
    parser.add_argument("--name", default="%", help="object name filter, SQL LIKE pattern (default: %%)")
    parser.add_argument("--output-dir", default="procedures", help="output directory (default: ./procedures)")
    args = parser.parse_args()

    cfg = load_config(args.config)
    owner = (args.owner or cfg["username"]).upper()
    out_dir = Path(args.output_dir)

    with connect(cfg) as conn:
        cursor = conn.cursor()
        configure_metadata(cursor)
        objects = list_objects(cursor, owner, args.types, args.name.upper())
        if not objects:
            print(f"No {', '.join(args.types)} objects found in schema {owner}")
            return

        out_dir.mkdir(parents=True, exist_ok=True)
        saved = 0
        for name, object_type, status in objects:
            ddl = get_ddl(cursor, owner, name, object_type)
            if not ddl:
                print(f"  skipped {object_type} {name}: no source available")
                continue
            path = out_dir / f"{name.lower()}.{object_type.lower().replace(' ', '_')}.sql"
            path.write_text(ddl.strip() + "\n")
            note = "" if status == "VALID" else f"  [{status}]"
            print(f"  saved {object_type} {name} -> {path}{note}")
            saved += 1

    print(f"Downloaded {saved} of {len(objects)} object(s) to {out_dir}/")


if __name__ == "__main__":
    main()
