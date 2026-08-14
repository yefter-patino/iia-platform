"""Where platformctl gets its resource names from.

Three sources, in precedence order:

  1. explicit arguments  -- what a test or a caller passes in
  2. environment         -- PLATFORMCTL_RAW_BUCKET and friends
  3. terraform output    -- read from envs/dev, cached for the process

Terraform is last because shelling out is slow and requires the working
directory to be initialised. It is included at all because typing bucket names
that contain an account ID is how typos happen.

Nothing here calls AWS. That is deliberate: config resolution is pure, so the
tests can construct a Config directly and never touch the network.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_DIR = REPO_ROOT / "envs" / "dev"

# env var -> terraform output name
_FIELDS = {
    "raw_bucket": "PLATFORMCTL_RAW_BUCKET",
    "curated_bucket": "PLATFORMCTL_CURATED_BUCKET",
    "glue_database": "PLATFORMCTL_GLUE_DATABASE",
    "glue_crawler": "PLATFORMCTL_GLUE_CRAWLER",
    "athena_workgroup": "PLATFORMCTL_ATHENA_WORKGROUP",
    "secret_name": "PLATFORMCTL_SECRET_NAME",
}


class ConfigError(RuntimeError):
    """Raised when a required setting cannot be resolved from any source."""


@dataclass(frozen=True)
class Config:
    raw_bucket: str
    curated_bucket: str
    glue_database: str
    glue_crawler: str
    athena_workgroup: str
    secret_name: str
    region: str = "us-east-1"


@lru_cache(maxsize=1)
def _terraform_outputs() -> dict:
    """Read `terraform output -json` once per process. {} if unavailable."""
    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=ENV_DIR,
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return {}

    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}

    return {key: value.get("value") for key, value in raw.items()}


def load(**overrides) -> Config:
    """Build a Config, preferring explicit values, then env, then Terraform."""
    tf = None
    resolved = {}
    missing = []

    for field, env_var in _FIELDS.items():
        value = overrides.get(field) or os.environ.get(env_var)

        if not value:
            # Only shell out to Terraform if something is still unresolved.
            if tf is None:
                tf = _terraform_outputs()
            value = tf.get(field if field != "glue_crawler" else "glue_crawler_name")
            if not value and field == "glue_database":
                value = tf.get("glue_database_name")
            if not value and field in ("raw_bucket", "curated_bucket"):
                value = tf.get(f"{field}_name")
            if not value and field == "athena_workgroup":
                value = tf.get("athena_workgroup_name")

        if not value:
            missing.append(env_var)
        else:
            resolved[field] = value

    if missing:
        raise ConfigError(
            "Could not resolve: "
            + ", ".join(missing)
            + ".\nSet them in the environment, or run from a repo whose envs/dev is applied."
        )

    region = overrides.get("region") or os.environ.get("AWS_REGION") or "us-east-1"
    return Config(region=region, **resolved)
