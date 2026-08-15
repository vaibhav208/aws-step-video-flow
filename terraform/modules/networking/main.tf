# ---------------------------------------------------------------------------
# Networking — Phase 2
#
# What this builds: one VPC, `az_count` PUBLIC subnets, an Internet Gateway,
# a public route table, a free S3 Gateway VPC Endpoint, and a security group
# for the ECS Fargate video-processor task.
#
# Why public subnets instead of the private-subnet-plus-NAT-Gateway pattern
# you'd default to for a long-running service: this project's only compute
# is a short-lived, on-demand Fargate TASK (not a service) invoked by Step
# Functions per Map iteration. It needs outbound internet to pull its image
# from ECR and call the S3/DynamoDB/CloudWatch/SNS APIs, and it never
# accepts inbound connections from anything. A NAT Gateway costs
# ~$0.045/hour (~$32/mo) PLUS per-GB data processing charges just to grant
# that same outbound-only access from a private subnet — for a task that
# runs for a few minutes per video, that's paying a full-time toll booth for
# occasional traffic. Running the task in a public subnet with
# `assign_public_ip = true` and a security group that allows ALL EGRESS but
# ZERO INGRESS gets the identical network-reachability outcome (the task can
# call out, nothing can call in) for $0.
#
# If you need private subnets for compliance reasons (e.g. "no task may
# ever hold a routable public IP", a real requirement in some environments),
# the alternative is: private subnets + VPC Interface Endpoints for ECR
# (api and dkr), CloudWatch Logs, and (Phase 3+) SNS/DynamoDB/Step
# Functions, plus the S3 Gateway Endpoint already included here. That
# removes the NAT Gateway cost too, at the price of several
# ~$7.30/mo-per-AZ interface endpoints — worth it once you have enough
# other private-subnet workloads to amortize them across, not worth it for
# this one task in a learning project.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${data.aws_availability_zones.available.names[count.index]}"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Free, no-bandwidth-charge path to S3 that keeps GetObject/PutObject
# traffic between the Fargate task and the media bucket off the public
# internet even though the task itself has a public IP. Gateway endpoints
# (unlike Interface endpoints) cost nothing beyond the route table entries
# they add, so there's no reason not to include this one.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-endpoint"
  })
}

data "aws_region" "current" {}

# Egress-only security group for the video-processor Fargate task. No
# ingress rules at all: this task is invoked by Step Functions' RunTask
# API, not by any inbound network connection, so it needs to make outbound
# calls (ECR, S3, CloudWatch Logs, and later DynamoDB/SNS/Step Functions
# callback APIs) and receive nothing.
resource "aws_security_group" "ecs_task" {
  name        = "${var.name_prefix}-ecs-task-sg"
  description = "Egress-only security group for the video-processor Fargate task"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound (ECR pull, S3/CloudWatch/DynamoDB/SNS API calls)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ecs-task-sg"
  })
}
