#!/usr/bin/env bash
# Bring the NAT Gateway back for a work session.
#
# The setting is written into envs/dev/terraform.tfvars, so it stays on until
# you run nat-off.sh -- it will not be undone by the next plain apply.

set -euo pipefail

"$(dirname "$0")/nat-toggle.sh" true

echo
echo "NAT Gateway is up. Remember to run nat-off.sh when you stop."
