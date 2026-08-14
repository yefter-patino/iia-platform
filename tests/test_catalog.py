"""Tests for Glue catalog operations.

The waiting functions take an injectable `sleep`, so these run instantly
instead of blocking for the real poll interval. A test suite that sleeps is a
test suite people stop running.
"""

from __future__ import annotations

import pytest

from platformctl import catalog

DATABASE = "yefter_dev_lake"


@pytest.fixture
def database(glue):
    glue.create_database(DatabaseInput={"Name": DATABASE})
    return DATABASE


@pytest.fixture
def crawler(glue, database, raw_bucket):
    name = "yefter-dev-telemetry"
    glue.create_crawler(
        Name=name,
        Role="arn:aws:iam::123456789012:role/test",
        DatabaseName=database,
        Targets={"S3Targets": [{"Path": f"s3://{raw_bucket}/telemetry/"}]},
    )
    return name


class TestCrawlerState:
    def test_reports_ready_before_any_run(self, glue, crawler):
        assert catalog.crawler_state(glue, crawler)["state"] == "READY"


class TestStartCrawler:
    def test_returns_true_when_it_starts(self, glue, crawler):
        assert catalog.start_crawler(glue, crawler) is True

    def test_returns_false_when_already_running(self, glue, crawler):
        catalog.start_crawler(glue, crawler)
        assert catalog.start_crawler(glue, crawler) is False


class TestWaitForCrawler:
    def test_returns_immediately_when_ready(self, glue, crawler):
        calls = []
        state = catalog.wait_for_crawler(glue, crawler, sleep=calls.append)

        assert state["state"] == "READY"
        assert calls == []

    def test_times_out_rather_than_hanging(self, glue, crawler):
        catalog.start_crawler(glue, crawler)

        with pytest.raises(catalog.CrawlerTimeout):
            catalog.wait_for_crawler(glue, crawler, timeout=0, sleep=lambda _: None)


class TestListTables:
    def test_empty_database(self, glue, database):
        assert catalog.list_tables(glue, database) == []

    def test_reports_columns_and_partition_keys(self, glue, database):
        glue.create_table(
            DatabaseName=database,
            TableInput={
                "Name": "telemetry",
                "StorageDescriptor": {
                    "Columns": [
                        {"Name": "srcaddr", "Type": "string"},
                        {"Name": "bytes", "Type": "int"},
                    ]
                },
                "PartitionKeys": [{"Name": "dt", "Type": "string"}],
            },
        )

        tables = catalog.list_tables(glue, database)

        assert tables == [{"name": "telemetry", "columns": 2, "partition_keys": ["dt"]}]


class TestRunQuery:
    """Athena is exercised with a stub rather than moto.

    moto's Athena support returns canned results and does not model query
    state transitions, so testing against it would assert on moto's behaviour
    rather than ours. A small stub makes the state machine explicit: the code
    must poll while QUEUED/RUNNING, raise on FAILED, and strip the header row
    on success.
    """

    class FakeAthena:
        def __init__(self, states, rows=None, reason=None):
            self.states = list(states)
            self.rows = rows or []
            self.reason = reason
            self.polls = 0

        def start_query_execution(self, **kwargs):
            self.kwargs = kwargs
            return {"QueryExecutionId": "qid-1"}

        def get_query_execution(self, QueryExecutionId):
            self.polls += 1
            state = self.states.pop(0) if self.states else "SUCCEEDED"
            status = {"State": state}
            if self.reason:
                status["StateChangeReason"] = self.reason
            return {"QueryExecution": {"Status": status, "Statistics": {"DataScannedInBytes": 2048}}}

        def get_query_results(self, QueryExecutionId):
            return {"ResultSet": {"Rows": self.rows}}

    @staticmethod
    def _rows(*records):
        return [{"Data": [{"VarCharValue": v} for v in record]} for record in records]

    def test_polls_until_success(self):
        athena = self.FakeAthena(["QUEUED", "RUNNING", "SUCCEEDED"], self._rows(["dt"], ["2026-08-13"]))

        result = catalog.run_query(athena, "SELECT 1", DATABASE, "wg", sleep=lambda _: None)

        assert athena.polls == 3
        assert result["columns"] == ["dt"]
        assert result["rows"] == [["2026-08-13"]]

    def test_strips_the_header_row(self):
        athena = self.FakeAthena(["SUCCEEDED"], self._rows(["a", "b"], ["1", "2"], ["3", "4"]))

        result = catalog.run_query(athena, "SELECT 1", DATABASE, "wg", sleep=lambda _: None)

        assert result["columns"] == ["a", "b"]
        assert result["rows"] == [["1", "2"], ["3", "4"]]

    def test_reports_bytes_scanned(self):
        athena = self.FakeAthena(["SUCCEEDED"], self._rows(["a"]))

        assert catalog.run_query(athena, "SELECT 1", DATABASE, "wg", sleep=lambda _: None)["bytes_scanned"] == 2048

    def test_raises_on_failure_with_the_reason(self):
        athena = self.FakeAthena(["FAILED"], reason="COLUMN_NOT_FOUND")

        with pytest.raises(catalog.QueryFailed, match="COLUMN_NOT_FOUND"):
            catalog.run_query(athena, "SELECT nope", DATABASE, "wg", sleep=lambda _: None)

    def test_raises_on_cancellation(self):
        """A query cancelled by the workgroup's scan ceiling lands here."""
        athena = self.FakeAthena(["CANCELLED"], reason="Bytes scanned limit was exceeded")

        with pytest.raises(catalog.QueryFailed, match="limit was exceeded"):
            catalog.run_query(athena, "SELECT *", DATABASE, "wg", sleep=lambda _: None)

    def test_passes_the_workgroup_so_the_ceiling_applies(self):
        athena = self.FakeAthena(["SUCCEEDED"], self._rows(["a"]))

        catalog.run_query(athena, "SELECT 1", DATABASE, "yefter-dev-wg", sleep=lambda _: None)

        assert athena.kwargs["WorkGroup"] == "yefter-dev-wg"

    def test_handles_an_empty_result_set(self):
        athena = self.FakeAthena(["SUCCEEDED"], [])

        result = catalog.run_query(athena, "SELECT 1", DATABASE, "wg", sleep=lambda _: None)

        assert result["rows"] == []
