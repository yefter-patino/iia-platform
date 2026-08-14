"""Secrets Manager access.

Note what is missing: any function that prints a secret value to stdout by
default. `get_secret` returns it to a caller, and the CLI requires an explicit
--reveal flag before it will display one. Secrets end up in shell history,
terminal scrollback and CI logs mostly because a tool made it the easy path.
"""

from __future__ import annotations

import json


class SecretNotFound(RuntimeError):
    pass


def describe_secret(client, name: str) -> dict:
    """Metadata only -- never the value."""
    try:
        secret = client.describe_secret(SecretId=name)
    except client.exceptions.ResourceNotFoundException as exc:
        raise SecretNotFound(name) from exc

    versions = secret.get("VersionIdsToStages") or {}
    return {
        "name": secret.get("Name"),
        "arn": secret.get("ARN"),
        "kms_key_id": secret.get("KmsKeyId"),
        "has_value": bool(versions),
        "versions": len(versions),
        "last_changed": secret.get("LastChangedDate"),
    }


def get_secret(client, name: str) -> str:
    try:
        return client.get_secret_value(SecretId=name)["SecretString"]
    except client.exceptions.ResourceNotFoundException as exc:
        raise SecretNotFound(name) from exc


def set_secret(client, name: str, payload: dict) -> str:
    """Store a dict as the secret's JSON value. Returns the version id.

    JSON rather than a bare string because a secret is almost never one value
    for long, and migrating a plain string to structured data later means
    updating every consumer at once.
    """
    response = client.put_secret_value(SecretId=name, SecretString=json.dumps(payload, sort_keys=True))
    return response["VersionId"]
