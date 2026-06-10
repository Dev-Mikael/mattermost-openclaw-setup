output "state_bucket_name" {
  description = "S3 bucket name used by scripts/02-terraform-provision.sh backend config"
  value       = aws_s3_bucket.state.bucket
}
