# Phase 1 — Network Foundation

The brief asks for one thing in writing: *why* each subnet is public or
private. That reasoning is the actual skill. Here it is.

## What got built

A `/16` VPC split into four `/24` subnets across two Availability Zones:

```
10.20.0.0/16                     VPC
├── 10.20.0.0/24   AZ-a  public   → route 0.0.0.0/0 to Internet Gateway
├── 10.20.1.0/24   AZ-b  public   → route 0.0.0.0/0 to Internet Gateway
├── 10.20.2.0/24   AZ-a  private  → route 0.0.0.0/0 to NAT Gateway
└── 10.20.3.0/24   AZ-b  private  → route 0.0.0.0/0 to NAT Gateway
```

Plus an Internet Gateway, one NAT Gateway with an Elastic IP, four route
tables (one public, one private per AZ), and two baseline security groups.

## Why a /16

A `/16` gives 65,536 addresses. This lab will never need them. The reason to
take the space anyway is that **VPC CIDR blocks cannot be shrunk**, and Phase 9
peers this VPC with a second one. Overlapping CIDRs make peering impossible —
so the CIDR you pick on day one constrains what you can connect on day thirty.
Picking `10.20.0.0/16` now leaves `10.30.0.0/16` free for the second account.

`cidrsubnet()` does the carving so the subnet ranges are derived from the VPC
CIDR rather than typed in. Change `vpc_cidr` and every subnet follows.

## What actually makes a subnet public

Nothing about the subnet itself. There is no "public" flag in AWS.

A subnet is public because **its route table has a route to an Internet
Gateway**. That is the entire difference. Same VPC, same AZ, same
`map_public_ip_on_launch` setting — swap the route table and a public subnet
becomes private.

This is the thing to say out loud in an interview, because most people describe
public subnets as a property of the subnet.

## Public subnets hold almost nothing

Only two things belong there:

- the **NAT Gateway** — it needs a route to the internet to do its job
- a load balancer, later

Everything with data on it goes private: EMR nodes, the ECS task, anything
touching the lake. If a compute resource does not need to be *reached from* the
internet, it should not sit where the internet can reach it.

## What the NAT Gateway is for

Private instances still need outbound access — `pip install`, `yum update`,
calls to the AWS APIs. The NAT lets connections go **out** and lets the replies
come back, but nothing on the internet can start a connection **in**.

Asymmetry is the point. Outbound-only is not the same as "no isolation."

Two things about it worth knowing:

1. **It lives in a public subnet.** It has to — it needs its own route to the
   IGW. Putting it in a private subnet is a classic first-time mistake and the
   symptom is a private instance that can't reach anything.
2. **It's the expensive part.** Roughly $0.045/hour plus per-GB data
   processing, billed whether traffic flows or not. That's why
   `enable_nat_gateway` is a variable and `scripts/nat-off.sh` exists.

## One NAT or one per AZ

This lab uses one, via `single_nat_gateway = true`.

The trade-off: with one NAT, private subnets in AZ-b send their egress across
to AZ-a. If AZ-a goes down, **both** AZs lose outbound. You also pay cross-AZ
data transfer.

In production you run one NAT per AZ so each AZ is independent. The module
supports it — set `single_nat_gateway = false` and it builds one per AZ, each
private route table pointing at the NAT in its own zone. The lab uses one
because two NATs is two dollars a day for zero learning.

Being able to explain the trade-off is worth more than having built the
expensive version.

## Security groups: stateful

Security groups are **stateful**. Allow traffic in, and the reply is allowed
out automatically — no matching outbound rule needed. Network ACLs are
**stateless** and do need both directions. That distinction comes up constantly.

The private workload SG has **no inbound rules from any CIDR**. It allows
traffic only from other members of the same security group, referenced by group
ID rather than by IP — so the rule keeps working no matter what addresses the
instances get.

To get a shell on a private instance, use SSM Session Manager rather than
opening port 22. No inbound rule, no bastion, no key pair to lose, and every
session is logged. That gets wired up in Phase 2 with the instance profile.

## Remote state

State lives in the S3 bucket from `bootstrap/`, with versioning on.

Locking uses `use_lockfile = true` — S3-native locking, which writes a small
`.tflock` object next to the state file using a conditional write. If a second
`terraform apply` starts while one is running, the write fails with a 412 and
Terraform stops instead of corrupting state.

This replaced the DynamoDB lock table. `dynamodb_table` still works but is
deprecated and slated for removal. Older tutorials all show the DynamoDB
pattern — knowing that it changed, and why, is a small current-awareness marker
worth having.

The bucket name is not in `backend.tf` because it contains the account ID. It
comes from `backend.hcl`, which is gitignored, passed via
`terraform init -backend-config=backend.hcl`.

## Done when

`terraform apply` builds the whole VPC from nothing, and an EC2 instance in a
private subnet can reach the internet through the NAT but is not reachable
from it.

The test instance is deliberately not in this code — launching it needs the
instance profile from Phase 2. That's the verification step for the end of
Phase 2, not a reason to open port 22 now.

## Things that broke / things learned

> Fill this in as you go. This section is the one interviewers actually want.
> A debugging story beats a clean architecture diagram every time.
