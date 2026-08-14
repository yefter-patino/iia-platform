"""platformctl -- operate the IIA platform without opening the console.

    platformctl status                 what exists and how big it is
    platformctl partitions             partitions present in the raw bucket
    platformctl crawl [--wait]         run the Glue crawler
    platformctl tables                 tables in the catalog
    platformctl query SQL              run Athena SQL, print a table
    platformctl anomalies [--top N]    the worst flows the Phase 4 job found
    platformctl secret show            secret metadata (never the value)
    platformctl secret set K=V [K=V]   store a JSON payload
    platformctl secret get --reveal    print the value, deliberately awkward
"""

from __future__ import annotations

import argparse
import sys

import boto3

from . import catalog, lake, secrets
from .config import Config, ConfigError, load


def _clients(cfg: Config):
    session = boto3.session.Session(region_name=cfg.region)
    return session


def _print_table(columns, rows) -> None:
    if not columns:
        print("(no rows)")
        return

    widths = [len(str(c)) for c in columns]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell if cell is not None else "")))

    line = "  ".join(str(c).ljust(widths[i]) for i, c in enumerate(columns))
    print(line)
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(str(c if c is not None else "").ljust(widths[i]) for i, c in enumerate(row)))


def cmd_status(cfg: Config, args) -> int:
    session = _clients(cfg)
    s3 = session.client("s3")
    glue = session.client("glue")

    for bucket in (cfg.raw_bucket, cfg.curated_bucket):
        summary = lake.summarize_bucket(s3, bucket)
        print(f"{bucket}")
        print(f"  {summary.objects:,} objects, {summary.human_size}")
        for name, entry in sorted(summary.prefixes.items()):
            print(f"    {name + '/':<16} {entry['objects']:>6,} objects  {lake.human_bytes(entry['bytes'])}")
        print()

    state = catalog.crawler_state(glue, cfg.glue_crawler)
    print(f"crawler {cfg.glue_crawler}: {state['state']} (last run {state['last_status']})")
    if state["last_error"]:
        print(f"  error: {state['last_error']}")

    tables = catalog.list_tables(glue, cfg.glue_database)
    print(f"catalog {cfg.glue_database}: {len(tables)} table(s)")
    for table in tables:
        parts = ",".join(table["partition_keys"]) or "none"
        print(f"    {table['name']:<20} {table['columns']:>3} columns  partitions: {parts}")
    return 0


def cmd_partitions(cfg: Config, args) -> int:
    s3 = _clients(cfg).client("s3")
    parts = lake.list_partitions(s3, cfg.raw_bucket, args.prefix)
    if not parts:
        print(f"no partitions under s3://{cfg.raw_bucket}/{args.prefix}")
        return 1
    for part in parts:
        print(part)
    return 0


def cmd_crawl(cfg: Config, args) -> int:
    glue = _clients(cfg).client("glue")

    if catalog.start_crawler(glue, cfg.glue_crawler):
        print(f"started {cfg.glue_crawler}")
    else:
        print(f"{cfg.glue_crawler} was already running")

    if not args.wait:
        return 0

    print("waiting...")
    state = catalog.wait_for_crawler(glue, cfg.glue_crawler)
    print(f"done: {state['last_status']}")
    return 0 if state["last_status"] == "SUCCEEDED" else 1


def cmd_tables(cfg: Config, args) -> int:
    glue = _clients(cfg).client("glue")
    tables = catalog.list_tables(glue, cfg.glue_database)
    _print_table(
        ["table", "columns", "partitions"],
        [[t["name"], t["columns"], ",".join(t["partition_keys"]) or "-"] for t in tables],
    )
    return 0


def cmd_query(cfg: Config, args) -> int:
    athena = _clients(cfg).client("athena")
    try:
        result = catalog.run_query(athena, args.sql, cfg.glue_database, cfg.athena_workgroup)
    except catalog.QueryFailed as exc:
        print(f"query failed: {exc}", file=sys.stderr)
        return 1

    _print_table(result["columns"], result["rows"])
    print(f"\n{lake.human_bytes(result['bytes_scanned'])} scanned")
    return 0


def cmd_anomalies(cfg: Config, args) -> int:
    sql = f"""
        SELECT dt, srcaddr, dstaddr, dstport, bytes,
               round(bytes_mod_zscore, 1) AS zscore, anomaly_reason
        FROM anomalies
        ORDER BY bytes DESC
        LIMIT {int(args.top)}
    """
    args.sql = sql
    return cmd_query(cfg, args)


def cmd_secret(cfg: Config, args) -> int:
    client = _clients(cfg).client("secretsmanager")

    try:
        if args.secret_action == "show":
            info = secrets.describe_secret(client, cfg.secret_name)
            for key, value in info.items():
                print(f"{key:<14} {value}")
            return 0

        if args.secret_action == "get":
            if not args.reveal:
                print("Refusing to print a secret without --reveal.", file=sys.stderr)
                return 2
            print(secrets.get_secret(client, cfg.secret_name))
            return 0

        payload = {}
        for pair in args.pairs:
            if "=" not in pair:
                print(f"expected KEY=VALUE, got {pair!r}", file=sys.stderr)
                return 2
            key, value = pair.split("=", 1)
            payload[key] = value

        version = secrets.set_secret(client, cfg.secret_name, payload)
        print(f"stored {len(payload)} key(s) as version {version}")
        return 0

    except secrets.SecretNotFound as exc:
        print(f"secret not found: {exc}", file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="platformctl", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="What exists in the lake and how big it is.")

    p_parts = sub.add_parser("partitions", help="Partitions present in the raw bucket.")
    p_parts.add_argument("--prefix", default="telemetry/")

    p_crawl = sub.add_parser("crawl", help="Run the Glue crawler.")
    p_crawl.add_argument("--wait", action="store_true", help="Block until it finishes.")

    sub.add_parser("tables", help="Tables in the Glue catalog.")

    p_query = sub.add_parser("query", help="Run Athena SQL.")
    p_query.add_argument("sql")

    p_anom = sub.add_parser("anomalies", help="Worst flows the Phase 4 job found.")
    p_anom.add_argument("--top", type=int, default=10)

    p_secret = sub.add_parser("secret", help="Inspect or set the application secret.")
    secret_sub = p_secret.add_subparsers(dest="secret_action", required=True)
    secret_sub.add_parser("show", help="Metadata only.")
    p_get = secret_sub.add_parser("get", help="Print the value.")
    p_get.add_argument("--reveal", action="store_true", help="Required. Prints the secret to stdout.")
    p_set = secret_sub.add_parser("set", help="Store KEY=VALUE pairs as JSON.")
    p_set.add_argument("pairs", nargs="+")

    return parser


HANDLERS = {
    "status": cmd_status,
    "partitions": cmd_partitions,
    "crawl": cmd_crawl,
    "tables": cmd_tables,
    "query": cmd_query,
    "anomalies": cmd_anomalies,
    "secret": cmd_secret,
}


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    try:
        cfg = load()
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    return HANDLERS[args.command](cfg, args)


if __name__ == "__main__":
    raise SystemExit(main())
