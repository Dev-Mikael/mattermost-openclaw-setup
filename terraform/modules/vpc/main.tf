# VPC module — networking foundation for the Kubernetes cluster
# Creates: VPC, 2 public subnets across different AZs, IGW, route tables
# All nodes run in public subnets for simplicity (learning project).
# Production upgrade path: add private subnets + NAT gateway for worker nodes.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # Required for Kubernetes DNS resolution
  enable_dns_hostnames = true # Required for AWS service endpoints

  tags = {
    Name        = "${var.cluster_name}-vpc"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Two public subnets in different AZs — required for the NLB to span AZs
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Nodes get public IPs on launch — required for direct SSH access
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.cluster_name}-public-${var.availability_zones[count.index]}"
    Environment = var.environment
    # kubernetes.io/role/elb tag tells AWS LB Controller this subnet hosts external LBs
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.cluster_name}-igw"
    Environment = var.environment
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.cluster_name}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
