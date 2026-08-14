"""Tests for Secrets Manager access."""

from __future__ import annotations

import json

import pytest

from platformctl import secrets


@pytest.fixture
def secret(secretsmanager):
    name = "yefter/dev/app"
    secretsmanager.create_secret(Name=name)
    return name


class TestDescribeSecret:
    def test_reports_no_value_before_one_is_set(self, secretsmanager, secret):
        info = secrets.describe_secret(secretsmanager, secret)

        assert info["name"] == secret
        assert info["has_value"] is False
        assert info["versions"] == 0

    def test_reports_a_value_once_set(self, secretsmanager, secret):
        secrets.set_secret(secretsmanager, secret, {"k": "v"})

        info = secrets.describe_secret(secretsmanager, secret)

        assert info["has_value"] is True
        assert info["versions"] >= 1

    def test_never_returns_the_value(self, secretsmanager, secret):
        """describe must not leak the secret, whatever else it reports."""
        secrets.set_secret(secretsmanager, secret, {"password": "hunter2"})

        info = secrets.describe_secret(secretsmanager, secret)

        assert "hunter2" not in json.dumps(info, default=str)

    def test_raises_for_missing_secret(self, secretsmanager):
        with pytest.raises(secrets.SecretNotFound):
            secrets.describe_secret(secretsmanager, "does/not/exist")


class TestSetAndGet:
    def test_round_trip(self, secretsmanager, secret):
        secrets.set_secret(secretsmanager, secret, {"user": "admin", "password": "hunter2"})

        assert json.loads(secrets.get_secret(secretsmanager, secret)) == {
            "user": "admin",
            "password": "hunter2",
        }

    def test_stores_sorted_json_for_stable_diffs(self, secretsmanager, secret):
        secrets.set_secret(secretsmanager, secret, {"b": "2", "a": "1"})

        assert secrets.get_secret(secretsmanager, secret) == '{"a": "1", "b": "2"}'

    def test_set_returns_a_version_id(self, secretsmanager, secret):
        assert secrets.set_secret(secretsmanager, secret, {"k": "v"})

    def test_later_write_supersedes_earlier(self, secretsmanager, secret):
        secrets.set_secret(secretsmanager, secret, {"k": "old"})
        secrets.set_secret(secretsmanager, secret, {"k": "new"})

        assert json.loads(secrets.get_secret(secretsmanager, secret))["k"] == "new"

    def test_get_raises_for_missing_secret(self, secretsmanager):
        with pytest.raises(secrets.SecretNotFound):
            secrets.get_secret(secretsmanager, "does/not/exist")
