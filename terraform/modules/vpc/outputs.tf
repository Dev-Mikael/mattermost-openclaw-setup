output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs — used by EC2 and NLB modules"
  value       = aws_subnet.public[*].id
}

output "vpc_cidr" {
  description = "VPC CIDR block — used for security group intra-cluster rules"
  value       = aws_vpc.main.cidr_block
}
