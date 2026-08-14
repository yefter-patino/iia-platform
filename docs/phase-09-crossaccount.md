# Phase 9 — S3 Gateway Endpoint and Cross-Account Access

Two unrelated things the roadmap puts together: one that saves money, one that
is about trust between accounts.

---

## Part 1 — The S3 gateway endpoint

Built early, out of phase order, because it is free and because Phase 4's EMR
job reads and writes S3 constantly. Without it, that traffic leaves through the
NAT Gateway and every byte is billed as NAT data processing.

**The distinction worth knowing:**

| type | services | cost | mechanism |
|---|---|---|---|
| Gateway | S3 and DynamoDB only | free | route table entries |
| Interface | everything else | ~$7/month per AZ | a real ENI |

Gateway endpoints are free because they are not infrastructure — they are
routes. Attaching one adds an entry to the route tables you associate it with:

```
Dest            Gateway                   Prefix
10.20.0.0/16    local                     None
0.0.0.0/0       nat-00d06bd426fa2908b     None
None            vpce-0860da524f4dc75e5    pl-63a5400a
```

`pl-63a5400a` is AWS's managed prefix list for S3 in us-east-1 — the set of
CIDRs S3 currently answers on, maintained by AWS. That entry is what sends
S3-bound traffic to the endpoint instead of the NAT.

Attached to the **private** route tables only. Public subnets already reach S3
through the Internet Gateway at no NAT cost.

There is no reason to run a private subnet without one.

---

## Part 2 — Cross-account `sts:AssumeRole`

**Honest label: this is a same-account simulation.** The lab has one AWS
account, so both halves of the handshake live in it. The mechanism is
identical — what changes in a real setup is a single account ID in the trust
policy. What a same-account build cannot demonstrate is the property that
actually matters in production: that the two sides are administered by
different people.

### Both sides must agree

This is the part worth internalising. Cross-account access requires permission
from **both** accounts, and neither can grant it alone:

```
Account B, in the role's TRUST policy:
    "principals from account A may assume me"

Account A, in an IDENTITY policy:
    "my principals may call sts:AssumeRole on that role in B"
```

Miss either half and you get `AccessDenied`. This is why naming an account root
as the trusted principal is not as loose as it looks: it means "any principal in
A **that also has AssumeRole permission**", and A's administrator controls the
second half. B's admin cannot hand out access to A's identities, and A's admin
cannot grant themselves a role in B.

### ExternalId and the confused deputy

The scenario it defends against:

You are a SaaS vendor. Customers X and Y both grant your account a role. Without
an `ExternalId`, X can discover Y's role ARN and ask you to assume it — and you,
the deputy, are confused into acting for X against Y's account. You had the
permission; you just used it on the wrong customer's behalf.

The shared value means X cannot make a request that satisfies Y's condition.

It is **not a password**. It is not secret from the parties involved and it is
not a substitute for the trust policy. It disambiguates *who asked*.

Verified:

```
$ aws sts assume-role --role-arn ...remote-lake-reader --role-session-name no-extid
AccessDenied

$ aws sts assume-role --role-arn ...remote-lake-reader --external-id yefter-iia-lab
arn:aws:sts::866934333672:assumed-role/yefter-dev-remote-lake-reader/with-extid
```

### The role is narrow

A role reachable from another account should be the most tightly scoped thing
you own, not the least. This one reads the curated bucket and catalog metadata,
nothing else. Verified by assuming it and trying:

```
$ aws s3 ls s3://...-curated-.../         # allowed
PRE anomalies/
PRE emr-logs/

$ aws s3 ls s3://...-raw-.../             # denied
AccessDenied: not authorized to perform: s3:ListBucket
```

Curated is derived data that can be regenerated. Raw is the thing that cannot
be, and a partner has no business reading it.

### Sessions are short

`max_session_duration = 3600`. The shorter the window, the less a leaked
session token is worth. `require_mfa` exists and is off by default, because
automation cannot present a token — a real decision rather than an oversight.

## Done when

The endpoint routes S3 traffic off the NAT, and the role can be assumed only
with the correct ExternalId, reaching only the curated bucket.

## Things that broke / things learned

- The first `terraform plan` after adding the endpoint reported `5 to add,
  1 to change, 3 to destroy` and wanted to recreate an existing bucket. It was a
  transient refresh failure — a re-plan returned `1 to add`. A saved plan file
  captures a moment; when one says something surprising, re-plan before applying.
