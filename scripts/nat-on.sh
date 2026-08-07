#!/usr/bin/env bash
# Bring the NAT Gateway back for a work session.

set -euo pipefail

cd "$(dirname "$0")/../envs/dev"

terraform apply -var="enable_nat_gateway=true"
echo
echo "NAT Gateway is up. Remember to run nat-off.sh when you stop."
