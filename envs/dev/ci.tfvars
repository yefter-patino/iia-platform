# Values CI plans against. terraform.tfvars is gitignored (it holds real
# addresses), so without this file CI plans against variable defaults and
# reports enormous phantom diffs -- including rebuilding the NAT Gateway,
# because enable_nat_gateway defaults to true.
#
# A plan that always shows 18 changes is a plan nobody reads, and the one time
# it shows something real, nobody notices.
#
# Only non-sensitive values belong here: this repository is public and Actions
# logs are public with it. The alert email is passed as a masked secret.

aws_region  = "us-east-1"
environment = "dev"
name_prefix = "yefter"
vpc_cidr    = "10.20.0.0/16"
az_count    = 2

# Matches the resting state of the lab. Both are the off switches.
enable_nat_gateway = false
api_desired_count  = 0

# The image currently deployed. Immutable tags mean this is a real version.
api_image_tag = "a34c66c"
