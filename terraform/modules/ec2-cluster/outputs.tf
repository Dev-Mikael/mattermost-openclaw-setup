output "control_plane_public_ip" {
  value = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  value = aws_instance.workers[*].public_ip
}

output "worker_private_ips" {
  value = aws_instance.workers[*].private_ip
}

output "worker_instance_ids" {
  description = "Worker EC2 instance IDs — used by NLB target group attachments"
  value       = aws_instance.workers[*].id
}

output "ssh_key_path" {
  description = "Local path to the generated private key file"
  value       = local_file.private_key.filename
}

output "ssh_key_name" {
  description = "AWS key pair name"
  value       = aws_key_pair.cluster.key_name
}
