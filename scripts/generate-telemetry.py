#!/usr/bin/env python3
"""Generate synthetic network flow telemetry and upload it to the raw bucket.

The lake needs something in it before a crawler has a schema to infer. This
writes VPC-flow-log-shaped records as newline-delimited JSON, one file per day,
under a Hive-style partition prefix:

    telemetry/dt=2026-08-13/flows-000.json

Why newline-delimited JSON rather than one big JSON array: every engine that
reads a lake -- Athena, Spark, Glue -- splits files on newlines so that workers
can read different byte ranges of the same file in parallel. A single array is
one indivisible value and cannot be split. It is the difference between a file
that scales and one that does not, and it costs nothing to get right now.

Why partition by date: Athena bills per byte scanned. A query filtered on
`dt` reads only the matching prefixes. Without partitions, every query reads
the whole dataset and you pay for all of it every time.

A small fraction of records are deliberately anomalous -- huge byte counts,
odd ports, REJECT actions -- so the Phase 4 anomaly job has something to find.

Usage:
    ./scripts/generate-telemetry.py --days 3 --records-per-day 5000
    ./scripts/generate-telemetry.py --days 1 --dry-run     # write locally only
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import random
import shutil
import subprocess
import sys
import tempfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# Ports a normal internal host talks to, weighted so HTTPS dominates.
COMMON_PORTS = [443] * 60 + [80] * 15 + [53] * 10 + [22] * 5 + [3306] * 5 + [5432] * 5

# Ports that should look wrong when they show up.
SUSPICIOUS_PORTS = [4444, 6667, 31337, 8888, 9001, 1337]

PROTOCOLS = {6: "TCP", 17: "UDP", 1: "ICMP"}


def host_pool(rng: random.Random, size: int) -> list:
    """A fixed set of internal hosts that all traffic comes from.

    This matters more than it looks. Drawing each srcaddr randomly from a /16
    gives ~1 flow per source across a dataset this size, and *any* per-source
    statistic is then meaningless: the median of one value is that value, the
    MAD is zero, and a z-score cannot be computed. The Phase 4 job degrades to
    its hardcoded port list without saying so.

    A real network has a bounded set of hosts that each talk repeatedly. The
    pool reproduces that, and it is what makes "unusual *for this host*"
    a question with an answer.
    """
    base = int(ipaddress.IPv4Address("10.20.0.0"))
    return [str(ipaddress.IPv4Address(base + rng.randint(1, 65000))) for _ in range(size)]


def external_ip(rng: random.Random) -> str:
    """A routable-looking address outside the VPC."""
    while True:
        addr = ipaddress.IPv4Address(rng.randint(1 << 24, (1 << 32) - 1))
        if not (addr.is_private or addr.is_loopback or addr.is_multicast or addr.is_reserved):
            return str(addr)


def make_record(rng: random.Random, day: date, anomalous: bool, hosts: list) -> dict:
    start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc) + timedelta(
        seconds=rng.randint(0, 86_399)
    )
    duration = rng.randint(1, 300)
    protocol = rng.choice([6, 6, 6, 17, 1])

    if anomalous:
        # Three shapes, deliberately. If every anomaly is both huge AND on a
        # suspicious port, the volume rule and the port rule agree on
        # everything, and the results cannot tell you which one is working --
        # a detector could have a completely dead statistical half and still
        # report perfect recall. Splitting the shapes is what makes the two
        # signals separable, and it is the difference between measuring the
        # detector and measuring the test data.
        #
        #   both        loud and obvious      -- caught by either rule
        #   volume_only exfiltration over 443 -- ONLY the statistics catch it
        #   port_only   quiet C2 beacon       -- ONLY the port list catches it
        kind = rng.choices(["both", "volume_only", "port_only"], weights=[5, 3, 2])[0]

        if kind == "port_only":
            # Small, ordinary-sized flow to a port that has no business being
            # there. A byte-count statistic cannot see this one at all.
            dst_port = rng.choice(SUSPICIOUS_PORTS)
            num_bytes = rng.randint(200, 250_000)
            packets = max(1, num_bytes // rng.randint(200, 1500))
        else:
            # Two orders of magnitude above normal: an exfiltration-shaped flow.
            num_bytes = rng.randint(50_000_000, 500_000_000)
            packets = rng.randint(40_000, 400_000)
            dst_port = rng.choice(COMMON_PORTS) if kind == "volume_only" else rng.choice(SUSPICIOUS_PORTS)

        action = rng.choice(["ACCEPT", "REJECT", "REJECT"])
    else:
        dst_port = rng.choice(COMMON_PORTS)
        num_bytes = rng.randint(200, 250_000)
        packets = max(1, num_bytes // rng.randint(200, 1500))
        action = "ACCEPT" if rng.random() > 0.03 else "REJECT"

    return {
        "version": 2,
        "start": int(start.timestamp()),
        "end": int((start + timedelta(seconds=duration)).timestamp()),
        "srcaddr": rng.choice(hosts),
        "dstaddr": external_ip(rng),
        "srcport": rng.randint(32768, 60999),
        "dstport": dst_port,
        "protocol": protocol,
        "protocol_name": PROTOCOLS.get(protocol, "OTHER"),
        "packets": packets,
        "bytes": num_bytes,
        "action": action,
        "log_status": "OK",
        "is_anomaly": anomalous,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=3, help="How many days of data, ending today (default 3).")
    parser.add_argument("--records-per-day", type=int, default=5000, help="Records per day (default 5000).")
    parser.add_argument(
        "--anomaly-rate", type=float, default=0.02, help="Fraction of anomalous records (default 0.02)."
    )
    parser.add_argument("--seed", type=int, default=None, help="Seed for reproducible output.")
    parser.add_argument(
        "--hosts",
        type=int,
        default=200,
        help="How many distinct internal hosts generate traffic (default 200). Keep this well below "
        "total records, or per-source statistics have nothing to compare against.",
    )
    parser.add_argument(
        "--s3-uri",
        default=None,
        help="Destination, e.g. s3://bucket/telemetry/. Defaults to `terraform output -raw telemetry_s3_uri`.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Write files locally and print the path; do not upload.")
    args = parser.parse_args()

    if args.days < 1 or args.records_per_day < 1:
        print("--days and --records-per-day must be at least 1", file=sys.stderr)
        return 2
    if not 0.0 <= args.anomaly_rate <= 1.0:
        print("--anomaly-rate must be between 0 and 1", file=sys.stderr)
        return 2

    rng = random.Random(args.seed)
    hosts = host_pool(rng, args.hosts)

    s3_uri = args.s3_uri
    if not s3_uri and not args.dry_run:
        env_dir = Path(__file__).resolve().parent.parent / "envs" / "dev"
        try:
            s3_uri = subprocess.run(
                ["terraform", "output", "-raw", "telemetry_s3_uri"],
                cwd=env_dir,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            print(f"Could not read telemetry_s3_uri from {env_dir}: {exc}", file=sys.stderr)
            print("Pass --s3-uri explicitly, or run from a applied dev environment.", file=sys.stderr)
            return 1

    if not args.dry_run and shutil.which("aws") is None:
        print("aws CLI not found on PATH; cannot upload. Use --dry-run.", file=sys.stderr)
        return 1

    workdir = Path(tempfile.mkdtemp(prefix="telemetry-"))
    today = datetime.now(timezone.utc).date()
    total = 0
    anomalies = 0

    for offset in range(args.days):
        day = today - timedelta(days=offset)
        part_dir = workdir / f"dt={day.isoformat()}"
        part_dir.mkdir(parents=True, exist_ok=True)
        path = part_dir / "flows-000.json"

        with path.open("w", encoding="utf-8") as handle:
            for _ in range(args.records_per_day):
                is_anomaly = rng.random() < args.anomaly_rate
                anomalies += is_anomaly
                handle.write(json.dumps(make_record(rng, day, is_anomaly, hosts)) + "\n")
                total += 1

        print(f"  wrote {args.records_per_day:>7,} records  {path.relative_to(workdir)}")

    per_host = total / len(hosts)
    print(f"\n{total:,} records across {args.days} day(s), {anomalies:,} anomalous ({anomalies / total:.1%})")
    print(f"{len(hosts)} distinct source hosts, ~{per_host:.0f} flows each -- enough for a per-source median")

    if args.dry_run:
        print(f"\nDry run. Files are in: {workdir}")
        return 0

    if not s3_uri.endswith("/"):
        s3_uri += "/"

    print(f"\nUploading to {s3_uri}")
    result = subprocess.run(
        ["aws", "s3", "cp", str(workdir), s3_uri, "--recursive", "--only-show-errors"],
        check=False,
    )
    if result.returncode != 0:
        print("Upload failed.", file=sys.stderr)
        return result.returncode

    shutil.rmtree(workdir, ignore_errors=True)
    print("Done. Now run the crawler so Athena can see it:")
    print("  aws glue start-crawler --name $(terraform -chdir=envs/dev output -raw glue_crawler_name)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
