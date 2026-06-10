variable "cluster_name" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }

variable "public_subnet_ids" {
  description = "Subnet IDs for EC2 instances (one per AZ)"
  type        = list(string)
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane. Use t3 not t2 (no credit exhaustion)."
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "worker_disk_size_gb" {
  description = "Root EBS volume size for workers in GB"
  type        = number
  default     = 40
}

variable "control_plane_instance_profile" {
  description = "IAM instance profile name for the control plane node"
  type        = string
}

variable "worker_instance_profile" {
  description = "IAM instance profile name for worker nodes"
  type        = string
}
