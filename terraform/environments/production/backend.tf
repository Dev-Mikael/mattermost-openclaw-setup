terraform {
  backend "s3" {
    bucket         = "mattermostb"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "mattermost-terraform-locks"
    encrypt        = true
  }
}
