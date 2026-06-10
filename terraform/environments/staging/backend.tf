# Remote state backend for staging.
# Backend values are supplied by scripts/02-terraform-provision.sh so the
# state bucket name never has to be copied into this file manually.

terraform {
  backend "s3" {}
}
