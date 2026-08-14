"""Glue catalog and Athena operations."""

from __future__ import annotations

import time


class CrawlerTimeout(RuntimeError):
    """The crawler did not return to READY within the timeout."""


class QueryFailed(RuntimeError):
    """Athena reported FAILED or CANCELLED."""


def crawler_state(glue, name: str) -> dict:
    """Current state plus the outcome of the last run."""
    crawler = glue.get_crawler(Name=name)["Crawler"]
    last = crawler.get("LastCrawl") or {}
    return {
        "state": crawler.get("State"),
        "last_status": last.get("Status"),
        "last_error": last.get("ErrorMessage"),
    }


def start_crawler(glue, name: str) -> bool:
    """Start the crawler. False if it was already running.

    Glue raises CrawlerRunningException rather than returning a status, so the
    already-running case is normal control flow and is caught here.
    """
    try:
        glue.start_crawler(Name=name)
        return True
    except glue.exceptions.CrawlerRunningException:
        return False


def wait_for_crawler(glue, name: str, timeout: int = 900, interval: int = 10, sleep=time.sleep) -> dict:
    """Block until the crawler is READY.

    `sleep` is injectable so tests do not actually wait.
    """
    deadline = time.monotonic() + timeout

    while True:
        state = crawler_state(glue, name)
        if state["state"] == "READY":
            return state
        if time.monotonic() >= deadline:
            raise CrawlerTimeout(f"{name} still {state['state']} after {timeout}s")
        sleep(interval)


def list_tables(glue, database: str) -> list:
    """Table names and column counts in a database."""
    tables = []
    paginator = glue.get_paginator("get_tables")
    for page in paginator.paginate(DatabaseName=database):
        for table in page.get("TableList", []):
            storage = table.get("StorageDescriptor") or {}
            tables.append(
                {
                    "name": table["Name"],
                    "columns": len(storage.get("Columns") or []),
                    "partition_keys": [k["Name"] for k in table.get("PartitionKeys") or []],
                }
            )
    return tables


def run_query(athena, sql: str, database: str, workgroup: str, timeout: int = 300, sleep=time.sleep) -> dict:
    """Run an Athena query to completion and return its rows.

    No output location is passed: the workgroup enforces one, and passing a
    different one would be rejected. That is the workgroup doing its job.
    """
    execution_id = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": database},
        WorkGroup=workgroup,
    )["QueryExecutionId"]

    deadline = time.monotonic() + timeout

    while True:
        execution = athena.get_query_execution(QueryExecutionId=execution_id)["QueryExecution"]
        status = execution["Status"]
        state = status["State"]

        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            reason = status.get("StateChangeReason", "no reason given")
            raise QueryFailed(f"{state}: {reason}")
        if time.monotonic() >= deadline:
            raise QueryFailed(f"still {state} after {timeout}s")

        sleep(2)

    scanned = execution.get("Statistics", {}).get("DataScannedInBytes", 0)
    result = athena.get_query_results(QueryExecutionId=execution_id)
    rows = result["ResultSet"]["Rows"]

    if not rows:
        return {"columns": [], "rows": [], "bytes_scanned": scanned}

    # Athena returns the header as the first row.
    header = [cell.get("VarCharValue") for cell in rows[0]["Data"]]
    body = [[cell.get("VarCharValue") for cell in row["Data"]] for row in rows[1:]]

    return {"columns": header, "rows": body, "bytes_scanned": scanned}
