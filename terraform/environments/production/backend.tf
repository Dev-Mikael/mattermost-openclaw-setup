terraform {
  backend "s3" {
    bucket       = "mattermostb"
    key          = "production/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
