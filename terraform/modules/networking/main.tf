terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── VPC ──────────────────────────────────────────────────────────────────────
# Isolated observability platform VPC. No peering with other platform VPCs.
# CIDR allocation: 10.1.0.0/16 (dev). See CLAUDE.md Networking section.
# No internet gateway — metric flow uses AWS service endpoints only.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "ai-observability-vpc-${var.environment}"
  })
}

# ── Private subnets ───────────────────────────────────────────────────────────
# Two private subnets across two AZs for high availability.
# No public subnets — all AWS service traffic uses service endpoints or
# AWS backbone routing (CloudWatch → Firehose → AMP is service-to-service).

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "ai-observability-private-${each.key}-${var.environment}"
    Tier = "private"
  })
}

# ── Route tables ─────────────────────────────────────────────────────────────
# One route table per private subnet. No routes beyond the local VPC CIDR —
# there is no NAT gateway or internet gateway in this environment.

resource "aws_route_table" "private" {
  for_each = var.private_subnets

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "ai-observability-rt-private-${each.key}-${var.environment}"
  })
}

resource "aws_route_table_association" "private" {
  for_each = var.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}
