# S3 module — Mattermost file storage bucket
# Replaces MinIO: no in-cluster object storage pod, no memory pressure,
# no container to manage. Files persist independently of the cluster lifecycle.

resource "aws_s3_bucket" "mattermost" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy # true for staging, false for production

  tags = {
    Name        = var.bucket_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Block all public access — Mattermost accesses files internally via IAM
resource "aws_s3_bucket_public_access_block" "mattermost" {
  bucket                  = aws_s3_bucket.mattermost.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "mattermost" {
  bucket = aws_s3_bucket.mattermost.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mattermost" {
  bucket = aws_s3_bucket.mattermost.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Lifecycle policy — transition older files to cheaper storage classes
resource "aws_s3_bucket_lifecycle_configuration" "mattermost" {
  bucket = aws_s3_bucket.mattermost.id

  rule {
    id     = "transition-old-files"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA" # Infrequent Access — cheaper for older files
    }
  }
}

# CORS configuration — required for Mattermost web client file uploads
resource "aws_s3_bucket_cors_configuration" "mattermost" {
  bucket = aws_s3_bucket.mattermost.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["https://${var.domain}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
