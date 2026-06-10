output "nlb_dns_name" {
  description = "NLB public DNS name — point your domain CNAME here"
  value       = aws_lb.ingress.dns_name
}

output "nlb_zone_id" {
  description = "NLB hosted zone ID — used for Route53 Alias records"
  value       = aws_lb.ingress.zone_id
}

output "nlb_arn" {
  value = aws_lb.ingress.arn
}
