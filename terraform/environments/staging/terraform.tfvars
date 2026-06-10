# Staging environment configuration
# Smaller instances = lower cost for testing

project_name                = "mm-openclaw"
secret_prefix               = "mattermost-openclaw-setup"
aws_region                  = "us-east-1"
domain                      = "staging.modumichael.me"
bucket_suffix               = "staging"
control_plane_instance_type = "t3.small"
worker_instance_type        = "t3.medium"
worker_count                = 3
