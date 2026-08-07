#!/usr/bin/env bash
# Phase 0 warm-up: confirm you are pointed at the right account, with the
# right identity, in the right region -- before you build anything.
#
# Usage:  ./scripts/check-identity.sh [profile-name]

set -euo pipefail

PROFILE="${1:-${AWS_PROFILE:-}}"

if [[ -z "$PROFILE" ]]; then
  echo "No profile given and AWS_PROFILE is not set."
  echo "Usage: $0 <profile-name>"
  exit 1
fi

export AWS_PROFILE="$PROFILE"

echo "Profile : $AWS_PROFILE"
echo "Region  : $(aws configure get region || echo '(not set)')"
echo

IDENTITY=$(aws sts get-caller-identity --output json)
ACCOUNT=$(echo "$IDENTITY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')
ARN=$(echo "$IDENTITY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')

echo "Account : $ACCOUNT"
echo "Identity: $ARN"
echo

# The check that matters. An ARN ending in ":root" means you are using the
# root user, which you should never do for daily work.
if [[ "$ARN" == *":root" ]]; then
  echo "STOP: you are authenticated as the ROOT user."
  echo "Create an admin IAM user, enable MFA on root, and re-run."
  exit 1
fi

echo "OK - not root. Safe to proceed."
