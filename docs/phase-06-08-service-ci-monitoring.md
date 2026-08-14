# Phases 6–8 — The Service, CI, and Monitoring

Three phases that share a theme: **identity instead of credentials**.

---

# Phase 6 — FastAPI on Fargate

## The two roles people conflate

ECS gives a task two roles, and they are not interchangeable:

| role | belongs to | used for |
|---|---|---|
| **execution role** | the ECS agent | pulling the image, creating the log group |
| **task role** | your process | what `boto3` inside the container picks up |

The common mistake is putting the application's permissions on the execution
role. It works, which is why it survives code review, but it means every image
pull happens with your data permissions attached, and the blast radius of a
compromised agent becomes your entire data layer.

Nothing in the image contains a credential. `boto3.Session()` is constructed
with no keys; inside ECS it finds the task role through the container
credentials endpoint, and on a laptop it finds the developer's profile. The
code is identical, which is the payoff for never hardcoding anything.

Proven from inside the running task:

```json
{"status":"ready","checks":{"s3":"ok","secret":"ok"}}
{"prefix":"telemetry/","count":3,"partitions":["dt=2026-08-11","dt=2026-08-12","dt=2026-08-13"]}
```

That is the container reading S3 *and* decrypting a KMS-encrypted secret with
no key material anywhere in the image.

## Liveness and readiness are different questions

`/healthz` makes **no AWS calls**. A liveness probe that depends on a
downstream service will cheerfully restart a perfectly healthy container during
someone else's outage, turning their incident into yours.

`/readyz` does call AWS, because "can this instance serve traffic" genuinely
depends on that. It returned 503 the first time it was called — correctly, the
secret had no value yet.

## Two things the Dockerfile gets right

**Non-root.** `USER app` (uid 1000). Verified: `uid=1000(app)`.

**Dependencies in their own layer,** installed before the application code is
copied. Editing `app.py` does not reinvalidate the layer that installs
FastAPI.

## No load balancer, on purpose

An ALB is ~$16/month — more than everything else in this project combined. The
service has **no inbound rules at all**; it is reached with
`aws ecs execute-command`. Add an ALB when something outside actually needs to
call it.

`enable_execute_command = true` on the service is only half of it. The **task
role** needs `ssmmessages:*`, because the SSM agent runs inside your container
under your identity. Without them the service starts perfectly and exec fails
with `TargetNotConnectedException`, which reads like a networking fault and is
not one. That bug was in this module until it was tested.

## The off switch

`desired_count = 0` leaves the service defined and stops all Fargate billing.
Cheaper and less destructive than `terraform destroy`, and a one-line change
back.

---

# Phase 7 — GitHub Actions with OIDC

## No stored keys

The old pattern is an IAM user's access key pasted into repository secrets:
long-lived, usable from anywhere on earth, only as safe as everyone who can
read the settings page, and rotated approximately never.

OIDC replaces it with a trust relationship. GitHub mints a short-lived signed
token describing which repository, branch and workflow is running. AWS verifies
it and returns credentials that expire in an hour. Nothing is stored.

## The `sub` claim is the entire security boundary

```
repo:yefter-patino/iia-platform:ref:refs/heads/main
repo:yefter-patino/iia-platform:pull_request
```

Get this wrong and you have not built a deployment role — you have built a role
**any repository on GitHub can assume**. `"*"` here is a catastrophe;
`repo:owner/name:*` is merely bad.

## CI can plan; CI cannot apply

Deliberate. Workflow files are edited in pull requests, so a workflow that can
apply means reviewing the `.tf` diff is not sufficient — someone could change
what runs at the same time as what it runs against. Applying stays a human
action until CI config is treated as production.

Note that a plan role is inherently broad in *reads*: `terraform plan` must
describe every resource it manages. That is the honest cost of plan-in-CI.

## One provider per account

The apply failed with:

```
EntityAlreadyExists: Provider with url https://token.actions.githubusercontent.com already exists
```

Another workload in this shared account had already registered GitHub. Only one
provider per URL can exist. The module takes `create_oidc_provider = false` and
an existing ARN, which is the right answer — importing it would let this lab
destroy something another tenant depends on.

---

# Phase 8 — Monitoring

## Every alarm must have an action

The rule: if nobody would do anything about it at 2am, it is not an alarm. An
alarm nobody acts on trains people to ignore the channel it arrives on, which
is worse than having no alarm at all.

So there is **no CPU alarm**. Brief saturation on a 0.25 vCPU task is normal
and has no action attached. What exists instead:

| alarm | why you would act |
|---|---|
| no running tasks | the API is down or crash-looping |
| errors in the logs | something is broken |
| **EMR cluster idle** | **money is leaking** |

The third is the one that matters here. Everything else in this lab fails
cheaply; a forgotten EMR cluster does not.

## `treat_missing_data` is a real decision

- **service down** → `missing`. This lab scales to zero deliberately and
  Container Insights stops publishing. `breaching` would page you for saving
  money.
- **EMR idle** → `notBreaching`. No clusters is the normal state.
- **log errors** → the metric filter sets `default_value = 0` so quiet periods
  publish zero rather than nothing, and the alarm sits in `OK` instead of
  `INSUFFICIENT_DATA`.

A dashboard full of grey is a dashboard nobody reads.

## The SNS trap

`aws_sns_topic_subscription` for email creates a subscription in
`PendingConfirmation` until someone clicks the link in the email. **Terraform
reports success either way.** An unconfirmed subscription looks exactly like a
working one right up until the first alarm goes nowhere.

If you take one operational habit from this phase: after adding an email
subscription, confirm it, then fire a test alarm and check it arrives.
