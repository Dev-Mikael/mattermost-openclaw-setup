output "bucket_name" { value = aws_s3_bucket.mattermost.bucket }
output "bucket_arn"  { value = aws_s3_bucket.mattermost.arn }
output "bucket_regional_domain_name" {
  value = aws_s3_bucket.mattermost.bucket_regional_domain_name
}
