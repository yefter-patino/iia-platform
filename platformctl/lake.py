"""Read-only inspection of the data lake.

Every function takes a boto3 client as its first argument rather than creating
one. That is the whole testing strategy: the tests hand these functions a
moto-backed client and no code has to know it is being tested. A module that
calls boto3.client() internally can only be tested by monkeypatching, which
tests the patch as much as the code.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class BucketSummary:
    bucket: str
    objects: int
    bytes: int
    prefixes: dict

    @property
    def human_size(self) -> str:
        return human_bytes(self.bytes)


def human_bytes(size: float) -> str:
    """Bytes as a human-readable string. 1536 -> '1.5 KiB'."""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(size) < 1024.0 or unit == "TiB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024.0
    return f"{size:.1f} TiB"


def summarize_bucket(s3, bucket: str, prefix: str = "") -> BucketSummary:
    """Count objects and bytes under a prefix, grouped by top-level folder.

    Uses a paginator because list_objects_v2 caps at 1000 keys per call and
    silently truncates otherwise -- a bug that hides until the lake grows.
    """
    objects = 0
    total = 0
    prefixes: dict = {}

    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            objects += 1
            total += obj["Size"]

            key = obj["Key"]
            top = key.split("/", 1)[0] if "/" in key else "(root)"
            entry = prefixes.setdefault(top, {"objects": 0, "bytes": 0})
            entry["objects"] += 1
            entry["bytes"] += obj["Size"]

    return BucketSummary(bucket=bucket, objects=objects, bytes=total, prefixes=prefixes)


def list_partitions(s3, bucket: str, prefix: str) -> list:
    """Return the Hive-style partition values directly under a prefix.

    telemetry/dt=2026-08-13/... -> ['dt=2026-08-13', ...]
    """
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    found = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix, Delimiter="/"):
        for common in page.get("CommonPrefixes", []):
            part = common["Prefix"][len(prefix) :].rstrip("/")
            if "=" in part:
                found.append(part)

    return sorted(found)
