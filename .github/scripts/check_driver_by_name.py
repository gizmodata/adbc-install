"""Load an installed GizmoData ADBC driver by name through the ADBC driver manager.

    python check_driver_by_name.py --driver oracle                  # "oracle" must load the Oracle driver
    python check_driver_by_name.py --driver oracle --name oracle-gd # the same driver, installed as "oracle-gd"
    python check_driver_by_name.py --driver oracle --absent         # "oracle" must not be found

Loading by name goes through the driver manifest (<drivers dir>/<name>.toml) only. No server is
needed: each driver is given a URI with its own scheme pointing at 127.0.0.1:1, where nothing
listens, and its connection error must carry text only that driver writes (checked by running each
driver's real release). That proves the library behind the manifest is the right driver, loaded
with the right entrypoint. Needs only adbc-driver-manager (no pyarrow).
"""

from __future__ import annotations

import argparse
import sys

import adbc_driver_manager as dm

# driver: (URI, text in the driver's own error when 127.0.0.1:1 refuses the connection,
#          (an unknown database option, the text of the driver's error for it) or None)
DRIVERS = {
    "oracle": ("oracle://user:pass@127.0.0.1:1/service", "oracle: cannot connect to 127.0.0.1:1", None),
    "db2": ("db2://user:pass@127.0.0.1:1/database", "drda: connect 127.0.0.1:1", None),
    "quack": ("quack://127.0.0.1:1", "(tried http://127.0.0.1:1/quack)", None),
    "gizmosql": ("gizmosql://127.0.0.1:1?transport=tcp", "[GizmoSQL] [FlightSQL] connection error", None),
    "chargewire": (
        "chargewire://127.0.0.1:1?tls=false",
        "[chargewire] connecting to http://127.0.0.1:1/chargewire",
        # Hardcharger's library would answer "[hardcharger] unknown option ...".
        ("adbc.hardcharger.no_such_option", "[chargewire] Unknown database option 'adbc.hardcharger.no_such_option'"),
    ),
    # Hardcharger's driver is built on Chargewire's, so its connection error says [chargewire]; the
    # option error tells the two apart.
    "hardcharger": (
        "hardcharger://127.0.0.1:1?tls=false",
        "connecting to http://127.0.0.1:1/chargewire",
        ("adbc.hardcharger.no_such_option", "[hardcharger] unknown option adbc.hardcharger.no_such_option"),
    ),
}


def connect_and_query(name: str, uri: str) -> None:
    with dm.AdbcDatabase(driver=name, uri=uri) as db:
        with dm.AdbcConnection(db) as conn:
            with dm.AdbcStatement(conn) as stmt:
                stmt.set_sql_query("SELECT 1")
                stmt.execute_query()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True, choices=sorted(DRIVERS))
    parser.add_argument("--name", help="the manifest name it was installed under (default: --driver)")
    parser.add_argument("--absent", action="store_true", help="the name must not be found")
    parser.add_argument("--print-probe", action="store_true", help="print the URI and error text, a line each (for the R check)")
    args = parser.parse_args()
    name = args.name or args.driver
    uri, connect_text, option_probe = DRIVERS[args.driver]
    if args.print_probe:
        print(uri)
        print(connect_text)
        return 0

    if args.absent:
        try:
            dm.AdbcDatabase(driver=name, uri=uri).close()
        except dm.Error as error:
            first = str(error).splitlines()[0]
            if error.status_code == dm.AdbcStatusCode.NOT_FOUND and f"Could not load `{name}`" in first:
                print(f"'{name}' is not installed, as expected")
                return 0
            print(f"'{name}' failed for another reason than not being found: {first}", file=sys.stderr)
            return 1
        print(f"'{name}' loaded, but it should not be installed", file=sys.stderr)
        return 1

    try:
        connect_and_query(name=name, uri=uri)
    except dm.Error as error:
        text = str(error)
        if error.status_code == dm.AdbcStatusCode.NOT_FOUND and "Could not load" in text:
            print(f"'{name}' is not found by name: {text.splitlines()[0][:300]}", file=sys.stderr)
            return 1
        if connect_text not in text:
            print(f"'{name}' loaded, but its error is not the {args.driver} driver's: {text[:400]}", file=sys.stderr)
            return 1
    else:
        print(f"'{name}' connected to 127.0.0.1:1, where nothing should listen", file=sys.stderr)
        return 1

    if option_probe is not None:
        option, option_text = option_probe
        try:
            dm.AdbcDatabase(driver=name, uri=uri, **{option: "1"}).close()
        except dm.Error as error:
            if option_text not in str(error):
                print(f"unknown option refused, but not by the {args.driver} driver: {error}", file=sys.stderr)
                return 1
        else:
            print(f"{option} was accepted", file=sys.stderr)
            return 1

    print(f"'{name}' loads the {args.driver} driver by name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
