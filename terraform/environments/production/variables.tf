variable "project_name" { type = string }
variable "secret_prefix" { type = string }
variable "aws_region" { type = string }
variable "domain" { type = string }
variable "control_plane_instance_type" { type = string }
variable "worker_instance_type" { type = string }
variable "worker_count" { type = number }
variable "bucket_suffix" {
  description = "Optional suffix for the Mattermost files S3 bucket. Defaults to the AWS account ID."
  type        = string
  default     = ""
}
