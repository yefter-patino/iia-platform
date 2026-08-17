# Capstone — The Whole Thing, End to End

What was built, what it proves, and — more usefully — what it does not.

## The pipeline

```
scripts/generate-telemetry.py
        │  12,000 NDJSON flow records, 200 hosts, 3 daily partitions
        ▼
S3 raw ──────────── telemetry/dt=YYYY-MM-DD/flows-000.json
        │
        ├──► Glue crawler ──► catalog table `telemetry` (dt as partition key)
        │                            │
        │                            ▼
        │                     Athena ── SQL over raw JSON
        ▼
Transient EMR cluster (auto-terminating)
        │  PySpark: modified z-score per source host + suspicious ports
        ▼
S3 curated ───────── anomalies/dt=YYYY-MM-DD/*.snappy.parquet
        │
        ├──► Glue crawler ──► catalog table `anomalies`
        │                            │
        ├──────────────┬─────────────┴──────────────┐
        ▼              ▼                            ▼
   platformctl    FastAPI on Fargate        cross-account role
   (operator CLI)  (task role, no keys)     (ExternalId, read-only)
```

Every arrow above was executed against a real AWS account, not diagrammed.

## The end-to-end run

```
$ ./scripts/generate-telemetry.py --days 3 --records-per-day 4000 --hosts 200
12,000 records across 3 day(s), 231 anomalous (1.9%)
200 distinct source hosts, ~60 flows each

$ ./scripts/run-emr-job.sh
read 12,000 flows
flagged 231 anomalous flows (1.93%)
ground truth: 231 planted | caught 231 | precision 100.0% | recall 100.0%
wrote 231 rows to s3://.../anomalies/

$ platformctl anomalies --top 3
dt          srcaddr        dstaddr         dstport  bytes      zscore  anomaly_reason
2026-08-12  10.20.20.117   167.225.2.7     6667     495134597  8048.2  volume+port
...
8.2 KiB scanned
```

And the same query through the deployed API, from inside the Fargate task:

```
columns: ['dt','srcaddr','dstaddr','dstport','bytes','zscore','anomaly_reason']
scanned 8377 bytes
```

## What this actually proves

**Identity replaces credentials, everywhere.** No access key exists in this
project. The container gets its permissions from a task role, CI gets them from
an OIDC token that expires in an hour, EMR nodes get them from an instance
profile, and the cross-account role requires a handshake from both sides. The
one secret that does exist is stored empty by Terraform and filled out of band,
so its value never enters state.

**Least privilege was verified, not asserted.** The Phase 2 policy names one
secret ARN. The cross-account role was assumed and then *proved* unable to read
the raw bucket:

```
$ aws s3 ls s3://...-curated-.../    # allowed
$ aws s3 ls s3://...-raw-.../        # AccessDenied
```

**Cost control is structural.** The crawler has no schedule. The Athena
workgroup cancels queries over 1 GiB. The EMR cluster auto-terminates whether
the job passes or fails. `desired_count = 0` and `enable_nat_gateway = false`
are one-line off switches. Total spend for this entire build was under $2.

## What it does not prove

This section matters more than the one above.

**~~The two detection signals are perfectly correlated.~~** *Fixed and
re-verified.* The generator now plants three anomaly shapes — loud (both
signals), exfiltration over port 443 (volume only), and a quiet beacon on a
suspicious port (port only). The results are now separable:

```
by_volume  by_port  volume_only  port_only  total
180        156      77           53         233
```

**Neither rule alone reaches 100% recall** — 180 and 156 of 233. The z-score
independently catches **77 large flows on entirely ordinary ports** that the
port list would have missed, and the port list catches 53 quiet flows the
statistics cannot see. Both halves of the detector demonstrably earn their
place, which is what the earlier runs could not show.


**Phase 9 is a same-account simulation.** The mechanism is identical, but the
property that matters in production — that the two sides are administered by
different people — cannot be demonstrated in one account.

**~~Phase 1's "done when" was never run.~~** *Done.* A `t4g.nano` was launched
into a private subnet with no public IP (`Public: null`), no key pair
(`Key: null`), and a security group whose only inbound rule references itself —
nothing from any CIDR. It registered with SSM in ~180 seconds and returned a
root shell on `10.20.2.12` through the Phase 2 instance profile. Instance
terminated afterwards.

**~~The Athena scan ceiling has never fired.~~** *Fired.* The lake is 3.3 MB, and
Athena's minimum cutoff is 10 MB, so no query against it can ever trip the
limit — the guardrail was untestable at this data volume. Verified instead
against a 21 MB table in a throwaway workgroup with the minimum cutoff:

```json
{"State": "CANCELLED",
 "Reason": "Bytes scanned limit was exceeded",
 "Scanned": 10485760}
```

It stopped at exactly the limit rather than scanning the file and billing for
it. Test table, data and workgroup were deleted afterwards.

**No Neo4j topology graph.** The roadmap asks for one; it needs a running
database, which is ongoing compute this lab turns off.

**The $10 budget does not work.** It has no cost filter, so it measures spend
across an account that carries unrelated workloads with $3,500/month and
$1,500/month budgets. It will never fire for this lab's costs. Fixing it needs
the `Project` tag activated as a cost allocation tag in the Billing console,
which is manual and not retroactive.

## The five bugs worth remembering

1. **`nat-off.sh` did not turn the NAT off.** It passed `-var`, which persists
   nothing, so the next plain apply rebuilt it. Verified by planning
   immediately after: `4 to add`.
2. **EMR validates the service-access security group but manages the other
   two.** Knowing which groups a service owns is not optional knowledge.
3. **`AmazonEMRServicePolicy_v2` hardcodes `iam:PassRole` to a role named
   `EMR_EC2_DefaultRole`.** The cluster said "insufficient EC2 permissions";
   CloudTrail said `iam:PassRole` on a named resource. *When a service error is
   vague, CloudTrail is specific.*
4. **`aws_security_group` with no egress blocks revokes AWS's default
   allow-all.** EMR adds ingress but never egress, so the cluster hung in
   `STARTING` with no error until killed.
5. **A detector reported 96.9% precision while its statistics did nothing.**
   10,982 sources across 12,000 flows meant every per-source median had a
   sample size of one.

Four of the five produced either no error message or a misleading one. The
common thread is that **the thing that reports success is rarely the thing that
knows the truth** — the plan file, the cluster event log, the precision number.
Checking a second source is what caught every one of them.

## Cost

| Phase | Idle cost |
|---|---|
| 1 network (NAT off) | free |
| 2 KMS + secret | ~$1.40/month |
| 3 lake | pennies |
| 4 EMR roles | free |
| 6 ECR + ECS at `desired_count = 0` | pennies |
| 7 OIDC role | free |
| 8 three alarms | ~$0.30/month |

**~$1.75/month at rest.** The expensive things — NAT, EMR, Fargate — are all
switched off and all have one-line switches back on.
