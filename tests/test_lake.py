"""Tests for lake inspection."""

from __future__ import annotations

import pytest

from platformctl import lake


class TestHumanBytes:
    @pytest.mark.parametrize(
        "size,expected",
        [
            (0, "0 B"),
            (512, "512 B"),
            (1024, "1.0 KiB"),
            (1536, "1.5 KiB"),
            (1024 * 1024, "1.0 MiB"),
            (3 * 1024**3, "3.0 GiB"),
        ],
    )
    def test_formats(self, size, expected):
        assert lake.human_bytes(size) == expected


class TestSummarizeBucket:
    def test_empty_bucket(self, s3, raw_bucket):
        summary = lake.summarize_bucket(s3, raw_bucket)
        assert summary.objects == 0
        assert summary.bytes == 0
        assert summary.prefixes == {}

    def test_counts_and_groups_by_prefix(self, s3, raw_bucket):
        s3.put_object(Bucket=raw_bucket, Key="telemetry/dt=2026-08-13/a.json", Body=b"x" * 100)
        s3.put_object(Bucket=raw_bucket, Key="telemetry/dt=2026-08-12/b.json", Body=b"x" * 200)
        s3.put_object(Bucket=raw_bucket, Key="other/c.json", Body=b"x" * 50)

        summary = lake.summarize_bucket(s3, raw_bucket)

        assert summary.objects == 3
        assert summary.bytes == 350
        assert summary.prefixes["telemetry"] == {"objects": 2, "bytes": 300}
        assert summary.prefixes["other"] == {"objects": 1, "bytes": 50}

    def test_respects_prefix_filter(self, s3, raw_bucket):
        s3.put_object(Bucket=raw_bucket, Key="telemetry/a.json", Body=b"x" * 10)
        s3.put_object(Bucket=raw_bucket, Key="other/b.json", Body=b"x" * 999)

        summary = lake.summarize_bucket(s3, raw_bucket, prefix="telemetry/")

        assert summary.objects == 1
        assert summary.bytes == 10

    def test_paginates_beyond_one_thousand_keys(self, s3, raw_bucket):
        """list_objects_v2 caps at 1000 keys; without a paginator this silently
        undercounts, which is the kind of bug that only appears in production."""
        for i in range(1005):
            s3.put_object(Bucket=raw_bucket, Key=f"telemetry/f{i:05d}.json", Body=b"x")

        summary = lake.summarize_bucket(s3, raw_bucket)

        assert summary.objects == 1005

    def test_human_size_property(self, s3, raw_bucket):
        s3.put_object(Bucket=raw_bucket, Key="telemetry/a.json", Body=b"x" * 2048)
        assert lake.summarize_bucket(s3, raw_bucket).human_size == "2.0 KiB"


class TestListPartitions:
    def test_finds_hive_partitions(self, s3, raw_bucket):
        for day in ("2026-08-11", "2026-08-12", "2026-08-13"):
            s3.put_object(Bucket=raw_bucket, Key=f"telemetry/dt={day}/flows.json", Body=b"{}")

        assert lake.list_partitions(s3, raw_bucket, "telemetry/") == [
            "dt=2026-08-11",
            "dt=2026-08-12",
            "dt=2026-08-13",
        ]

    def test_ignores_directories_without_equals(self, s3, raw_bucket):
        s3.put_object(Bucket=raw_bucket, Key="telemetry/dt=2026-08-13/a.json", Body=b"{}")
        s3.put_object(Bucket=raw_bucket, Key="telemetry/_temporary/b.json", Body=b"{}")

        assert lake.list_partitions(s3, raw_bucket, "telemetry/") == ["dt=2026-08-13"]

    def test_normalises_missing_trailing_slash(self, s3, raw_bucket):
        s3.put_object(Bucket=raw_bucket, Key="telemetry/dt=2026-08-13/a.json", Body=b"{}")

        assert lake.list_partitions(s3, raw_bucket, "telemetry") == ["dt=2026-08-13"]

    def test_empty_when_nothing_matches(self, s3, raw_bucket):
        assert lake.list_partitions(s3, raw_bucket, "nothing/") == []
