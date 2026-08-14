"""A small read-only API over the lake.

Phase 6's point is not the API. It is that a container running in a private
subnet, holding no credentials, can read a secret and query a data lake purely
because of the role attached to its task. Nothing in this file contains an
access key, and nothing in the image does either.

Endpoints:

    GET /healthz          liveness -- no AWS calls, so it stays up when AWS is not
    GET /readyz           readiness -- proves the AWS dependencies actually work
    GET /partitions       partitions present in the raw bucket
    GET /anomalies?top=N  worst flows the Phase 4 job found
    GET /config           what the service thinks it is, minus anything secret
"""

from __future__ import annotations

import os
from functools import lru_cache

import boto3
from fastapi import FastAPI, HTTPException, Query

from platformctl import catalog, lake, secrets

app = FastAPI(
    title="yefter-iia-platform",
    description="Read-only API over the network telemetry lake.",
    version="0.1.0",
)


class Settings:
    """Configuration from the environment, which is how a container is told
    anything. The ECS task definition supplies these."""

    def __init__(self) -> None:
        self.region = os.environ.get("AWS_REGION", "us-east-1")
        self.raw_bucket = os.environ.get("RAW_BUCKET", "")
        self.curated_bucket = os.environ.get("CURATED_BUCKET", "")
        self.glue_database = os.environ.get("GLUE_DATABASE", "")
        self.athena_workgroup = os.environ.get("ATHENA_WORKGROUP", "")
        self.secret_name = os.environ.get("SECRET_NAME", "")


@lru_cache(maxsize=1)
def settings() -> Settings:
    return Settings()


@lru_cache(maxsize=1)
def session() -> boto3.session.Session:
    """One session for the process.

    No credentials are passed. Inside ECS, boto3 finds them through the task
    role via the container credentials endpoint. On a laptop it finds the
    developer's profile. The code is identical either way, which is the point
    of never hardcoding credentials.
    """
    return boto3.session.Session(region_name=settings().region)


@app.get("/healthz")
def healthz() -> dict:
    """Liveness. Deliberately makes no AWS calls.

    A liveness probe that depends on a downstream service will cheerfully
    restart a perfectly healthy container during someone else's outage.
    """
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    """Readiness. Does touch AWS, because that is what it is for."""
    cfg = settings()
    checks: dict = {}

    try:
        session().client("s3").head_bucket(Bucket=cfg.raw_bucket)
        checks["s3"] = "ok"
    except Exception as exc:  # noqa: BLE001 - report, do not crash the probe
        checks["s3"] = f"error: {type(exc).__name__}"

    try:
        info = secrets.describe_secret(session().client("secretsmanager"), cfg.secret_name)
        checks["secret"] = "ok" if info["has_value"] else "no value set"
    except Exception as exc:  # noqa: BLE001
        checks["secret"] = f"error: {type(exc).__name__}"

    ready = all(v == "ok" for v in checks.values())
    if not ready:
        raise HTTPException(status_code=503, detail=checks)

    return {"status": "ready", "checks": checks}


@app.get("/config")
def config() -> dict:
    """What the service is pointed at. Never the secret's value."""
    cfg = settings()
    return {
        "region": cfg.region,
        "raw_bucket": cfg.raw_bucket,
        "curated_bucket": cfg.curated_bucket,
        "glue_database": cfg.glue_database,
        "athena_workgroup": cfg.athena_workgroup,
        "secret_name": cfg.secret_name,
    }


@app.get("/partitions")
def partitions(prefix: str = "telemetry/") -> dict:
    cfg = settings()
    found = lake.list_partitions(session().client("s3"), cfg.raw_bucket, prefix)
    return {"prefix": prefix, "count": len(found), "partitions": found}


@app.get("/anomalies")
def anomalies(top: int = Query(10, ge=1, le=100)) -> dict:
    cfg = settings()
    sql = f"""
        SELECT dt, srcaddr, dstaddr, dstport, bytes,
               round(bytes_mod_zscore, 1) AS zscore, anomaly_reason
        FROM anomalies
        ORDER BY bytes DESC
        LIMIT {int(top)}
    """

    try:
        result = catalog.run_query(
            session().client("athena"), sql, cfg.glue_database, cfg.athena_workgroup
        )
    except catalog.QueryFailed as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return {
        "columns": result["columns"],
        "rows": result["rows"],
        "bytes_scanned": result["bytes_scanned"],
    }
