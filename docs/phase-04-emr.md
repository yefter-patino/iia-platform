# Phase 4 — Anomaly Detection on Transient EMR

The first phase where something can go badly wrong with the bill, and the
first where the code has an opinion about statistics.

## Why Terraform does not create the cluster

`modules/emr` creates roles, an instance profile and security groups. It does
not create a cluster.

The cluster is *transient*: it starts, runs one step, and terminates itself.
Terraform describes state that should persist, and a resource that deletes
itself moments after creation makes the state file lie — every later `plan`
would offer to rebuild a cluster nobody wants. So the durable pieces are
Terraform's, and `scripts/run-emr-job.sh` creates the ephemeral one with
`--auto-terminate`.

`--auto-terminate` shuts the cluster down when the last step finishes,
**whether it succeeded or failed**. Combined with
`ActionOnFailure: TERMINATE_CLUSTER`, there is no path where a failed job
leaves two m5.xlarge instances running overnight.

## Why median and MAD, not mean and standard deviation

The job flags a flow when its byte count is extreme *for that source host*.
The obvious way is a z-score: how many standard deviations from the mean.

That does not work, for a reason worth understanding: **the outliers you are
hunting are in the sample you are measuring**. One 500 MB exfiltration inflates
the mean and the standard deviation enough that the flow lands inside one
sigma of a distribution it created. The bigger the anomaly, the better it hides.

The modified z-score uses the median and the median absolute deviation:

```
0.6745 * (x - median) / MAD
```

Both are order statistics. Adding one enormous value barely moves the median
and barely moves the MAD, so the outlier stays outlier-shaped. `0.6745` is the
0.75 quantile of the standard normal, which rescales the MAD so the result is
comparable to an ordinary z-score. 3.5 is the conventional cutoff.

## The bug that made the statistics decorative

The first run reported precision 96.9% and recall 100.0%. Both numbers were
real. Both were also almost entirely produced by a hardcoded list of suspicious
ports, not by any statistics.

Breaking the detections down by which rule fired:

| signal | detections | avg MB |
|---|---|---|
| `port` alone | 244 | 290.6 |
| `volume` alone | 8 | 0.2 |
| `volume+port` | 5 | 261.8 |

The volume rule fired 13 times out of 257, and the eight it caught *by itself*
averaged 0.2 MB — small flows, not exfiltration.

The cause was in the data generator, not the job:

```sql
SELECT count(*) AS flows, count(DISTINCT srcaddr) AS sources FROM telemetry
--  12000 flows, 10982 sources
```

Roughly **one flow per source**. The generator drew each `srcaddr` at random
from a /16, so almost every host appeared once. A per-source median of a single
value is that value; the MAD is zero; the divide-by-zero guard returns a score
of 0.0. Every per-source statistic silently evaluated to nothing, and the job
degraded to its port list without reporting that it had.

The fix is one concept in the generator: a **bounded pool of hosts** that talk
repeatedly, which is what a real network looks like. 200 hosts across 12,000
flows gives ~60 flows each — enough for a median to mean something.

The lesson is not about Spark. It is that a metric can be *correct* and still
measure nothing, and that "precision 96.9%" is not evidence that the thing you
built is the thing doing the work. Breaking results down by which rule fired is
what surfaced it.

## Three ways the cluster failed before it ran

Worth recording, because none of the error messages named the actual problem.

**1. `ServiceAccessSecurityGroup is missing ingress rule ... port 9443`**

EMR *manages* the master and core security groups — it writes the inter-node
rules itself. It does **not** manage the service access group; it validates it
and refuses to launch. The asymmetry is the trap. That group needs inbound 9443
from the master group and outbound 8443 to master and core.

**2. `Service role ... has insufficient EC2 permissions`**

This one names neither the permission nor the resource. CloudTrail had the real
error:

```
RunInstances -> Client.UnauthorizedOperation
not authorized to perform: iam:PassRole on resource: role/yefter-dev-emr-ec2
```

`AmazonEMRServicePolicy_v2` does grant `iam:PassRole` — for exactly one
resource:

```json
"Sid": "PassRoleForEC2",
"Resource": "arn:aws:iam::*:role/EMR_EC2_DefaultRole"
```

The role name is hardcoded in the AWS-managed policy. Most tutorials work
because they name their role `EMR_EC2_DefaultRole`. In an account shared with
unrelated workloads that name is generic enough to collide, so this module
grants `PassRole` explicitly for its own role instead.

**When a cluster event says something vague, CloudTrail has the specific
version.** That is the transferable part.

**3. The cluster hung in `STARTING` with no error at all**

The one that cost real money. `aws_security_group` in Terraform manages the
egress list as a whole, so a resource with **no egress blocks** does not mean
"leave AWS's default alone" — it means "there should be no egress rules", and
Terraform revokes the allow-all rule AWS creates. EMR adds ingress rules but
never egress, so the nodes could not reach package repositories or the EMR
service. Nothing errored, because from EMR's side nothing had failed yet; it
simply sat in *Configuring cluster software* until killed.

Cost of learning it: about eleven cents. Cost of not noticing for a day: about
eleven dollars.

## Cost

| Thing | Cost |
|---|---|
| Roles, instance profile, security groups | free |
| m5.xlarge (master + core) | ~$0.24/hr each including the EMR uplift |
| A ~10 minute run | ~$0.10 |

Bootstrap is ~7 minutes of that, billed, before your code runs. Transient
clusters are cheap per run and expensive per accident.

## Done when

`./scripts/run-emr-job.sh` launches a cluster, the step completes, Parquet
lands in the curated bucket partitioned by date, and the cluster terminates
itself.

## Things that broke / things learned

- EMR manages some of your security groups and validates others. Know which.
- Cluster events are vague; CloudTrail is specific.
- Terraform's `aws_security_group` revokes AWS's default egress rule.
- A detector can report excellent precision and recall while its main mechanism
  does nothing. Break results down by which rule fired.
