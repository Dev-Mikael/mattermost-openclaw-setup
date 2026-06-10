terraform {
  backend "s3" {
    bucket         = "REPLACE-WITH-YOUR-STATE-BUCKET-NAME"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "mattermost-terraform-locks"
    encrypt        = true
  }
}
