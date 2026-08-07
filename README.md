# yefter-iia-platform

A personal lab that builds a miniature Infrastructure Intelligence & Analytics
platform on AWS: synthetic network telemetry landing in a data lake, processed,
exposed through a small internal tool, delivered by CI/CD, and monitored.

Everything is Terraform. Nothing is created by clicking in the console.

**This is a self-driven learning project, not paid production work.**

---

## Repo layout

```
bootstrap/          run once - creates the Terraform state bucket + budget alarm
modules/
  network/          reusable VPC module (Phase 1)
envs/
  dev/              the dev environment - calls the modules
scripts/            helper shell scripts
docs/               one write-up per phase
```

`bootstrap/` keeps its state on your laptop. Everything under `envs/` keeps
state in S3.

---

## One-time setup

### 1. AWS profile

Create a named profile so nothing depends on default credentials:

```bash
aws configure --profile platform-lab
```

You will be prompted for the access key, secret, region and output format.
Those values are written to `~/.aws/credentials` on your Mac. They never go in
this repo — `.gitignore` blocks `.tfvars`, `credentials`, `.env` and `*.pem`,
and the pre-commit hooks scan for keys on every commit.

Confirm you are not on the root user:

```bash
./scripts/check-identity.sh platform-lab
```

### 2. Toolchain

```bash
brew install terraform awscli git pre-commit
brew install --cask docker
pre-commit install
```

Terraform **1.11 or newer** is required — the S3 backend in this repo uses
native state locking (`use_lockfile`), which went GA in 1.11.

### 3. Bootstrap the state bucket and the budget

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output state_bucket_name
```

Set the budget email to an address you actually read. AWS sends a confirmation
mail for the budget subscription — click it or the alerts never arrive.

### 4. Point dev at the remote state

```bash
cd ../envs/dev
cp backend.hcl.example backend.hcl              # paste in the bucket name
cp terraform.tfvars.example terraform.tfvars    # then edit it
terraform init -backend-config=backend.hcl
```

---

## The loop you'll repeat all project

```bash
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

And at the end of a session:

```bash
./scripts/nat-off.sh     # kills the NAT Gateway, keeps the VPC
```

---

## Cost control

The three expensive things in this project are **NAT Gateway, EMR, and
Transit Gateway**. Phase 1 only has the first one.

| Resource | Cost | Note |
|---|---|---|
| VPC, subnets, route tables, security groups | free | leave them up |
| Internet Gateway | free | leave it up |
| NAT Gateway | ~$0.045/hr + data | **the one to watch** — about $1/day |
| Elastic IP attached to NAT | free while attached | charged if left unattached |
| S3 state bucket | pennies | leave it up |

`nat-off.sh` sets `enable_nat_gateway = false` and re-applies, so you tear down
only the NAT and its EIP. The VPC survives, which means the next morning is one
command instead of a full rebuild.

---

## Git workflow

One branch per phase, opened as a merge request, self-reviewed, then merged.

```bash
git checkout -b phase-1-network
# ...work...
git add -A && git commit -m "Phase 1: VPC, subnets, NAT, route tables"
git push -u origin phase-1-network
```

Then open the MR in GitLab, read your own diff properly, and merge.

Reading your own diff is not a formality — it is where you catch the hardcoded
value you meant to parameterise.

---

## Phases

| Phase | What it builds | Status |
|---|---|---|
| 0 | Account safety, toolchain, Git workflow | ✅ in this repo |
| 1 | VPC, subnets, NAT, routing, security groups | ✅ in this repo |
| 2 | IAM roles, least-privilege policies, Secrets Manager | next |
| 3 | S3 data lake + Glue crawler/ETL + Athena | |
| 4 | PySpark anomaly job on transient EMR | |
| 5 | `platformctl` Python CLI + boto3 + pytest/moto | |
| 6 | FastAPI service in Docker, pushed to ECR, run on ECS | |
| 7 | GitLab CI: lint → test → plan → build → deploy | |
| 8 | CloudWatch alarms + Prometheus/Grafana | |
| 9 | S3 gateway endpoint, cross-account `sts:AssumeRole` | |
| Capstone | End-to-end run, Neo4j topology graph, architecture write-up | |

Phase 9 attaches the S3 gateway endpoint to the private route tables — that is
why `private_route_table_ids` is already an output of the network module.
