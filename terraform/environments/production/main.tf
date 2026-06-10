terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  cluster_name = "${var.project_name}-production"
  environment  = "production"
}

module "vpc" {
  source              = "../../modules/vpc"
  cluster_name        = local.cluster_name
  environment         = local.environment
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
}

module "iam" {
  source         = "../../modules/iam"
  cluster_name   = local.cluster_name
  environment    = local.environment
  s3_bucket_name = module.s3.bucket_name
  secret_prefix  = var.secret_prefix
}

module "ec2" {
  source                         = "../../modules/ec2-cluster"
  cluster_name                   = local.cluster_name
  environment                    = local.environment
  vpc_id                         = module.vpc.vpc_id
  vpc_cidr                       = module.vpc.vpc_cidr
  public_subnet_ids              = module.vpc.public_subnet_ids
  control_plane_instance_type    = var.control_plane_instance_type
  worker_instance_type           = var.worker_instance_type
  worker_count                   = var.worker_count
  worker_disk_size_gb            = 40
  control_plane_instance_profile = module.iam.control_plane_instance_profile
  worker_instance_profile        = module.iam.worker_instance_profile
}

module "nlb" {
  source              = "../../modules/nlb"
  cluster_name        = local.cluster_name
  environment         = local.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  worker_instance_ids = module.ec2.worker_instance_ids
}

module "s3" {
  source        = "../../modules/s3"
  bucket_name   = "${var.project_name}-production-files-${var.bucket_suffix}"
  environment   = local.environment
  domain        = var.domain
  force_destroy = false # Protect production files
}

module "secrets" {
  source                 = "../../modules/secrets"
  environment            = local.environment
  secret_prefix          = var.secret_prefix
  secret_recovery_window = 7
}
