# ---------------------------------------------------------------------------
# NETWORK MODULE
#
# Builds the VPC that every later phase lives inside:
#
#   VPC
#    |-- public subnets  (one per AZ)  -> route to Internet Gateway
#    |-- private subnets (one per AZ)  -> route to NAT Gateway
#    |-- Internet Gateway
#    |-- NAT Gateway (in a public subnet, with an Elastic IP)
#    |-- security groups
#
# The rule to remember: a subnet is "public" only because its route table
# has a route to an Internet Gateway. Nothing else makes it public.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"

  # Pick the first N Availability Zones that are actually usable in this
  # region. Never hardcode "us-east-1a" -- it is not the same physical zone
  # in two different accounts, and it breaks the moment you change region.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve the VPC CIDR into equal subnets.
  # With a /16 and newbits = 8 you get /24s:
  #   index 0,1 -> public   (10.20.0.0/24, 10.20.1.0/24)
  #   index 2,3 -> private  (10.20.2.0/24, 10.20.3.0/24)
  # Public subnets take the low indexes, private take the next block.
  public_subnet_cidrs = [
    for i in range(var.az_count) :
    cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, i)
  ]

  private_subnet_cidrs = [
    for i in range(var.az_count) :
    cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, i + var.az_count)
  ]

  # One NAT for the whole VPC, or one per AZ.
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC --------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both of these are needed for private DNS names inside the VPC, and for
  # VPC endpoints later in Phase 9. Turn them on now and forget about them.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, var.vpc_extra_tags, {
    Name = "${local.name}-vpc"
  })
}

# --- Internet Gateway -------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-igw"
  })
}

# --- Subnets ----------------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Anything launched here gets a public IP automatically. Convenient for a
  # bastion or NAT, and exactly what you do NOT want on a private subnet.
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${local.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, var.private_subnet_extra_tags, {
    Name = "${local.name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# --- NAT Gateway ------------------------------------------------------------
# A NAT Gateway lets private instances start outbound connections (apt,
# pip, calls to the AWS APIs) while nothing on the internet can start a
# connection inward. It needs a static public IP, which is the Elastic IP.

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${local.name}-nat-eip-${count.index}"
  })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id

  # The NAT itself sits in a PUBLIC subnet. This trips everyone up once.
  subnet_id = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${local.name}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

# --- Route tables -----------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-rt-public"
  })
}

# This single route is what makes the public subnets public.
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ, so that with single_nat_gateway = false
# each AZ can use its own NAT and stay independent.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-rt-private-${local.azs[count.index]}"
  })
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # If there is only one NAT, every private route table points at it.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- S3 gateway endpoint ----------------------------------------------------
#
# Without this, a private instance reaching S3 goes out through the NAT
# Gateway and every byte is billed as NAT data processing. With it, the
# traffic never leaves the AWS network: entries are added to the private route
# tables sending S3-bound prefixes to the endpoint instead of to the NAT.
#
# There are two kinds of VPC endpoint and the difference matters:
#
#   Gateway   S3 and DynamoDB only. Free. Works by adding route table
#             entries -- no ENI, no hourly charge.
#   Interface Everything else (SSM, ECR, Secrets Manager...). ~$7/month per
#             endpoint per AZ, because each one is a real ENI.
#
# This is a gateway endpoint, so it is free and there is no reason not to have
# it. Phase 4's EMR job reads and writes S3 constantly; routing that through
# the NAT would be paying per gigabyte for nothing.
#
# Note it attaches to the PRIVATE route tables only. Public subnets already
# reach S3 through the Internet Gateway at no NAT cost.

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Associating the endpoint with a route table is what actually creates the
  # route. An endpoint with no associations is inert.
  route_table_ids = aws_route_table.private[*].id

  tags = merge(var.tags, {
    Name = "${local.name}-s3-endpoint"
  })
}

data "aws_region" "current" {}

# --- Baseline security groups -----------------------------------------------
# Security groups are stateful: allow traffic in, and the reply is allowed
# out automatically. You do not need a matching rule for the response.

resource "aws_security_group" "private_workload" {
  name        = "${local.name}-sg-private-workload"
  description = "Default security group for private workloads. No inbound from the internet."
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-sg-private-workload"
  })
}

# Allow instances that share this security group to talk to each other.
# Referencing the SG by ID instead of by CIDR means the rule keeps working
# no matter what IPs the instances get.
resource "aws_vpc_security_group_ingress_rule" "private_self" {
  security_group_id            = aws_security_group.private_workload.id
  referenced_security_group_id = aws_security_group.private_workload.id
  ip_protocol                  = "-1"
  description                  = "Allow all traffic between members of this security group"
}

resource "aws_vpc_security_group_egress_rule" "private_all_out" {
  security_group_id = aws_security_group.private_workload.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound (reaches the internet via NAT)"
}

# Deliberately no inbound rules. Use SSM Session Manager to get a shell on a
# private instance instead of opening port 22. That is also a Phase 2 topic.
resource "aws_security_group" "public_ingress" {
  name        = "${local.name}-sg-public-ingress"
  description = "Attach to public-facing resources. Add inbound rules explicitly when a phase needs them."
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-sg-public-ingress"
  })
}

resource "aws_vpc_security_group_egress_rule" "public_all_out" {
  security_group_id = aws_security_group.public_ingress.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound"
}
