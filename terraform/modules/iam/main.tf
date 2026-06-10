# IAM module — least-privilege roles for EC2 instances
#
# Control plane profile: SSM Session Manager only (for browser-based terminal access
#   without SSH as an alternative). No AWS service permissions needed on CP.
#
# Worker profile: Secrets Manager read (for ESO), S3 read/write (for Mattermost),
# and EBS CSI permissions for durable Kubernetes PersistentVolumes.
#   Scoped to mattermost-specific resources only — not AdministratorAccess.
#
# This is the kubeadm equivalent of IRSA: all pods on a worker node share the
# node's instance profile. On EKS you'd use pod-level IRSA for finer granularity.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Control plane role ────────────────────────────────────────────────────────
resource "aws_iam_role" "control_plane" {
  name = "${var.cluster_name}-${var.environment}-control-plane"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Environment = var.environment }
}

# SSM access — lets you open a shell without SSH (useful backup access)
resource "aws_iam_role_policy_attachment" "control_plane_ssm" {
  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "control_plane" {
  name = "${var.cluster_name}-${var.environment}-control-plane"
  role = aws_iam_role.control_plane.name
}

# ── Worker role ──────────────────────────────────────────────────────────────
resource "aws_iam_role" "workers" {
  name = "${var.cluster_name}-${var.environment}-workers"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "workers_ssm" {
  role       = aws_iam_role.workers.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# AWS-managed policy for the EBS CSI controller. On this kubeadm cluster we use
# node instance profiles instead of IRSA, so the controller inherits this worker
# role when it runs on worker nodes.
resource "aws_iam_role_policy_attachment" "workers_ebs_csi" {
  role       = aws_iam_role.workers.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Least-privilege S3 policy — scoped to the Mattermost bucket only
resource "aws_iam_policy" "workers_s3" {
  name        = "${var.cluster_name}-${var.environment}-workers-s3"
  description = "Mattermost file storage access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAcl",
          "s3:PutObjectAcl"
        ]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}"
      }
    ]
  })
}

# Least-privilege Secrets Manager policy — scoped to this project's secret prefix
resource "aws_iam_policy" "workers_secrets" {
  name        = "${var.cluster_name}-${var.environment}-workers-secrets"
  description = "ESO access to Mattermost secrets in Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ]
      Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "workers_s3" {
  role       = aws_iam_role.workers.name
  policy_arn = aws_iam_policy.workers_s3.arn
}

resource "aws_iam_role_policy_attachment" "workers_secrets" {
  role       = aws_iam_role.workers.name
  policy_arn = aws_iam_policy.workers_secrets.arn
}

resource "aws_iam_instance_profile" "workers" {
  name = "${var.cluster_name}-${var.environment}-workers"
  role = aws_iam_role.workers.name
}
