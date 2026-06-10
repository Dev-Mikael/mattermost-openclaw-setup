# Remote state backend for staging
# Run terraform/state-backend/ FIRST to create the S3 bucket.
# Then replace the placeholder values below with the actual outputs.

terraform {
  backend "s3" {
    bucket       = "mattermostb"
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
