"""Shared fixtures.

moto intercepts boto3 at the HTTP layer, so the code under test uses ordinary
boto3 clients and never knows the difference. Nothing here talks to AWS, which
is why these tests are safe to run in CI with no credentials.

The fake credentials matter: without them boto3 may find real ones on the
machine, and a test that accidentally reaches a real account is worse than a
test that fails.
"""

from __future__ import annotations

import os

import boto3
import pytest
from moto import mock_aws

REGION = "us-east-1"


@pytest.fixture(autouse=True)
def fake_credentials(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    # Never let a test read the developer's real profile.
    monkeypatch.delenv("AWS_PROFILE", raising=False)


@pytest.fixture
def aws(fake_credentials):
    with mock_aws():
        yield


@pytest.fixture
def s3(aws):
    return boto3.client("s3", region_name=REGION)


@pytest.fixture
def glue(aws):
    return boto3.client("glue", region_name=REGION)


@pytest.fixture
def secretsmanager(aws):
    return boto3.client("secretsmanager", region_name=REGION)


@pytest.fixture
def raw_bucket(s3):
    name = "test-raw-bucket"
    s3.create_bucket(Bucket=name)
    return name
