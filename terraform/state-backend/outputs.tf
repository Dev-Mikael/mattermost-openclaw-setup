output "state_bucket_name" {
  description = "S3 bucket name — use this in environments/*/backend.tf"
  value       = aws_s3_bucket.state.bucket
}

output "lock_table_name" {
  description = "DynamoDB table name — use this in environments/*/backend.tf"
  value       = aws_dynamodb_table.state_lock.name
}
