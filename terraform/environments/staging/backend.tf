# Remote state backend for staging
# Run terraform/state-backend/ FIRST to create the S3 bucket and DynamoDB table.
# Then replace the placeholder values below with the actual outputs.

terraform {
  backend "s3" {
    bucket         = "mattermostb"
    key            = "staging/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "mattermost-terraform-locks"
    encrypt        = true
  }
}
