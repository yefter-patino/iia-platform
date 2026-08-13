#!/usr/bin/env bash
# Shared implementation behind nat-off.sh and nat-on.sh.
#
# Usage:  nat-toggle.sh <true|false> [extra terraform apply args...]
#
# Why this exists: the obvious version of these scripts was
#
#     terraform apply -var="enable_nat_gateway=false" -auto-approve
#
# and that is a trap. -var applies to one invocation and persists nothing, so
# terraform.tfvars still said `true` afterwards and the next plain
# `terraform apply` -- the one in the daily loop in the README -- quietly
# rebuilt the NAT Gateway and restarted the billing you thought you had
# stopped. The flag has to be written down, not passed in.

set -euo pipefail

DESIRED="${1:-}"
shift || true

if [[ "$DESIRED" != "true" && "$DESIRED" != "false" ]]; then
  echo "Usage: $0 <true|false> [terraform apply args...]" >&2
  exit 1
fi

cd "$(dirname "$0")/../envs/dev"

TFVARS="terraform.tfvars"

if [[ ! -f "$TFVARS" ]]; then
  echo "No $TFVARS in $(pwd)." >&2
  echo "Copy terraform.tfvars.example to terraform.tfvars and fill it in first." >&2
  exit 1
fi

# Rewrite the value if the key is there, append it if it is not. Written to a
# temp file and moved into place so an interrupted run cannot leave you with
# a half-written tfvars.
if grep -qE '^[[:space:]]*enable_nat_gateway[[:space:]]*=' "$TFVARS"; then
  TMP="$(mktemp)"
  sed -E "s/^([[:space:]]*enable_nat_gateway[[:space:]]*=[[:space:]]*).*/\1${DESIRED}/" "$TFVARS" >"$TMP"
  mv "$TMP" "$TFVARS"
else
  printf '\nenable_nat_gateway = %s\n' "$DESIRED" >>"$TFVARS"
fi

echo "Set enable_nat_gateway = ${DESIRED} in envs/dev/${TFVARS}"
echo

terraform apply "$@"
