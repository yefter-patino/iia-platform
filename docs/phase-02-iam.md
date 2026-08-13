# Phase 2 — Identity and Secrets

Phase 1 asked *why* a subnet is public. This phase asks a harder one: **how do
you give something permission to read one secret, and nothing else?**

Attaching `SecretsManagerReadWrite` takes ten seconds and is what most people
do. Writing a policy that names a single resource ARN takes longer and is the
entire point.

## What got built

```
KMS key (customer-managed, rotating)
 └── encrypts
      Secrets Manager secret   yefter/dev/app
       └── readable by
            IAM role  yefter-dev-secret-reader
             └── via  IAM policy naming exactly one secret ARN
```

Six resources: the key, its alias, the secret, the role, the policy, and the
attachment.

## Why a customer-managed key at all

Secrets Manager will encrypt with the AWS-managed key (`aws/secretsmanager`)
for free, and for most labs that is the correct, boring answer.

The reason to pay ~$1/month for our own: **the AWS-managed key's policy cannot
be edited**. You can never say "only this role may decrypt with this key."
Key-level control is only possible on a customer-managed key, and key-level
control is what makes the next section work.

That is the trade being made — a dollar a month for the ability to write the
policy at all. If the answer had been "because customer-managed is more
secure," that would be cargo cult.

## The policy worth reading twice

```json
{
  "Sid": "ReadOneSecret",
  "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
  "Resource": "arn:aws:secretsmanager:us-east-1:<account>:secret:yefter/dev/app-jDXahr"
}
```

`Resource` is one ARN. Not `*`. Not a prefix with a wildcard. If this role
leaks, the blast radius is one secret, not every secret in an account that also
runs unrelated workloads.

Note the `-jDXahr` suffix. Secrets Manager appends six random characters to
every secret ARN, which is why the policy interpolates
`aws_secretsmanager_secret.app.arn` rather than building the string by hand.
A hand-written ARN would be wrong and would fail closed at runtime — the kind
of bug that looks like a permissions mystery for an hour.

The second statement is the one people forget:

```json
{
  "Sid": "DecryptWithOneKeyViaSecretsManager",
  "Action": "kms:Decrypt",
  "Resource": "<the one key ARN>",
  "Condition": { "StringEquals": { "kms:ViaService": "secretsmanager.us-east-1.amazonaws.com" } }
}
```

Reading an encrypted secret needs **two** permissions: read the secret, and
decrypt with the key. Grant only the first and `GetSecretValue` fails with an
access-denied that names KMS, not Secrets Manager — confusing the first time.

The `kms:ViaService` condition means this role can only use the key *through
Secrets Manager*. It cannot take the key and decrypt something else that
happens to be encrypted with it.

## Why Terraform does not know the secret's value

There is no `aws_secretsmanager_secret_version` in this module, deliberately.

Terraform would need the plaintext to create one, and **everything Terraform is
given ends up in the state file**. The state is encrypted in S3, but "encrypted
at rest somewhere I can read" is not the same as "secret". Anyone with read
access to the state bucket would have the value.

So Terraform creates the empty container and the value goes in out of band:

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw secret_name)" \
  --secret-string '{"example":"replace-me"}'
```

This split — Terraform owns the resource, something else owns the contents — is
the normal production pattern, not a lab shortcut.

## What is deliberately absent

**No account-wide IAM settings.** `aws_iam_account_password_policy`, account
alias, root MFA enforcement: all of these apply to the *entire AWS account*,
and this account carries workloads that have nothing to do with this lab.
A phase that changes the login rules for unrelated users has overstepped. In a
dedicated lab account these would belong here; in a shared one they do not.

**No Glue / EMR / ECS roles.** Phases 3, 4 and 6 create those services. Writing
their roles now would mean guessing at permissions for resources that do not
exist, and rewriting them when they do. The reusable piece is the *pattern*
above, not a pile of speculative roles.

## Known gap: the SSM instance profile

`docs/phase-01-network.md` says twice that Phase 2 supplies an instance profile
so you can reach a private instance with SSM Session Manager, and calls that
the verification step for Phase 1:

> The test instance is deliberately not in this code — launching it needs the
> instance profile from Phase 2.

**That is not in this phase.** It needs an `aws_iam_instance_profile`, the
`AmazonSSMManagedInstanceCore` managed policy, and either a NAT or three VPC
interface endpoints for SSM to reach the service from a private subnet. Until
it exists, Phase 1's "done when" test has not actually been run.

It is a small addition and the natural first thing to add next.

## Cost

| Resource | Cost |
|---|---|
| KMS customer-managed key | ~$1.00/month |
| Secrets Manager secret | ~$0.40/month |
| IAM role, policy, attachment | free |

About **$1.40/month**, and unlike the NAT it does not stop when you stop
working. Destroy it with `terraform destroy -target=module.iam` if the lab goes
idle for a long stretch; the 7-day KMS deletion window means the key lingers
before it is really gone.

## Done when

`terraform apply` creates all six resources, `aws iam get-policy-version`
returns a document whose `Resource` is a single secret ARN, and the secret's
value can be set with `put-secret-value` without that value ever appearing in
`terraform.tfstate`.

Verified on apply: rotation enabled (365-day period), secret encrypted with the
customer-managed key, and the policy document containing no wildcards.

## Things that broke / things learned

> Fill this in as you go. This section is the one interviewers actually want.
> A debugging story beats a clean architecture diagram every time.
