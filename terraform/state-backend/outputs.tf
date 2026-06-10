output "state_bucket_name" {
  description = "S3 bucket name — use this in environments/*/backend.tf"
  value       = aws_s3_bucket.state.bucket
}
