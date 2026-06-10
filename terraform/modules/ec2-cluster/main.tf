# EC2 Cluster module — provisions control plane + worker nodes for kubeadm
# Generates an RSA key pair, writes the private key to disk, creates instances
# with appropriate security groups for Kubernetes communication.

terraform {
  required_providers {
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── SSH Key Pair ─────────────────────────────────────────────────────────────
resource "tls_private_key" "cluster" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "cluster" {
  key_name   = "${var.cluster_name}-${var.environment}-key"
  public_key = tls_private_key.cluster.public_key_openssh

  tags = {
    Name        = "${var.cluster_name}-${var.environment}-key"
    Environment = var.environment
  }
}

# Write private key to the environment directory for SSH access
# path.root = terraform/environments/{env}/ when applied from there
resource "local_file" "private_key" {
  content         = tls_private_key.cluster.private_key_pem
  filename        = "${path.root}/${var.cluster_name}-key.pem"
  file_permission = "0600"
}

# ── Security Groups ──────────────────────────────────────────────────────────

# Control plane security group
resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-${var.environment}-cp"
  description = "Kubernetes control plane"
  vpc_id      = var.vpc_id

  # SSH — restrict to your IP in production; 0.0.0.0/0 for learning convenience
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API server — used by kubectl and workers to join
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # etcd — only needs to be reachable within VPC
  ingress {
    description = "etcd"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Kubelet API + controller/scheduler — intra-cluster only
  ingress {
    description = "Kubelet and control plane components"
    from_port   = 10250
    to_port     = 10259
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Flannel VXLAN — intra-cluster pod networking overlay
  ingress {
    description = "Flannel VXLAN"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow all outbound — required for apt, image pulls, Let's Encrypt, push proxy
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-${var.environment}-cp-sg"
    Environment = var.environment
  }
}

# Worker node security group
resource "aws_security_group" "workers" {
  name        = "${var.cluster_name}-${var.environment}-workers"
  description = "Kubernetes worker nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubelet — used by control plane to manage pods
  ingress {
    description = "Kubelet"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NodePorts for nginx-ingress — NLB forwards 80→30080, 443→30443
  ingress {
    description = "nginx NodePort HTTP"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "nginx NodePort HTTPS"
    from_port   = 30443
    to_port     = 30443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flannel VXLAN
  ingress {
    description = "Flannel VXLAN"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NodePort range — allows kubeadm health checks and inter-cluster services
  ingress {
    description = "NodePort range"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-${var.environment}-workers-sg"
    Environment = var.environment
  }
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Ubuntu's official AWS account)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Control plane node — hosts kube-apiserver, etcd, controller-manager, scheduler
resource "aws_instance" "control_plane" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.control_plane.id]
  key_name                    = aws_key_pair.cluster.key_name
  iam_instance_profile        = var.control_plane_instance_profile
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30 # GB — control plane needs space for etcd snapshots
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.cluster_name}-${var.environment}-control-plane"
    Role        = "control-plane"
    Environment = var.environment
  }
}

# Worker nodes — run application pods (Mattermost, CNPG, nginx, ESO, etc.)
resource "aws_instance" "workers" {
  count = var.worker_count

  ami           = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  # Distribute workers across subnets/AZs for resilience
  subnet_id                   = var.public_subnet_ids[count.index % length(var.public_subnet_ids)]
  vpc_security_group_ids      = [aws_security_group.workers.id]
  key_name                    = aws_key_pair.cluster.key_name
  iam_instance_profile        = var.worker_instance_profile
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.worker_disk_size_gb
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.cluster_name}-${var.environment}-worker-${count.index + 1}"
    Role        = "worker"
    Environment = var.environment
  }
}
