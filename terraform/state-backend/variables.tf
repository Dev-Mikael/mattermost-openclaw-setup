variable "aws_region" {
  description = "AWS region for state storage"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state. Use your account ID as a suffix."
  type        = string
  # Example: "mattermost-tfstate-123456789012"
}
