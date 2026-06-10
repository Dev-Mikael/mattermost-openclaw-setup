output "control_plane_public_ip"  { value = module.ec2.control_plane_public_ip }
output "control_plane_private_ip" { value = module.ec2.control_plane_private_ip }
output "worker_public_ips"        { value = module.ec2.worker_public_ips }
output "worker_private_ips"       { value = module.ec2.worker_private_ips }
output "worker_instance_ids"      { value = module.ec2.worker_instance_ids }
output "ssh_key_path"             { value = module.ec2.ssh_key_path }
output "nlb_dns_name"             { value = module.nlb.nlb_dns_name }
output "s3_bucket_name"           { value = module.s3.bucket_name }

output "next_steps" {
  value = <<-EOT
    ✓ Infrastructure provisioned for PRODUCTION.
    NLB DNS: ${module.nlb.nlb_dns_name}
    Point ${var.domain} CNAME → ${module.nlb.nlb_dns_name}
    SSH key: ${module.ec2.ssh_key_path}
  EOT
}
