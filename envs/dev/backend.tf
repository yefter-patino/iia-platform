# ---------------------------------------------------------------------------
# Remote state.
#
# The bucket name is deliberately NOT written here -- it contains your account
# ID. It is passed in at init time from backend.hcl, which is gitignored:
#
#   terraform init -backend-config=backend.hcl
#
# use_lockfile = true is S3-native state locking. It writes a small .tflock
# object next to the state file using an S3 conditional write, so a second
# terraform apply fails fast instead of corrupting state. This replaced the
# old DynamoDB lock table -- the dynamodb_table argument is deprecated now.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
