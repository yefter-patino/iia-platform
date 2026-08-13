#!/usr/bin/env bash
# End-of-day cost control.
#
# The NAT Gateway is the one thing in Phase 1 that bills by the hour whether
# you use it or not (roughly a dollar a day, plus data). This destroys just
# the NAT and its Elastic IP and leaves the VPC, subnets and routes alone,
# so tomorrow you flip it back on instead of rebuilding everything.
#
# The setting is written into envs/dev/terraform.tfvars, so a later
# `terraform apply` with no arguments will not bring the NAT back.
#
# Turn it back on:  ./scripts/nat-on.sh

set -euo pipefail

"$(dirname "$0")/nat-toggle.sh" false -auto-approve

echo
echo "NAT Gateway destroyed. VPC and subnets are still there (and free)."
