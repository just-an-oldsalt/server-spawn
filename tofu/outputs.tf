output "minecraft_domain" {
  description = "DNS name players connect to"
  value       = var.domain_name
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.minecraft.id
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  value       = local.hosted_zone_id
}

output "lambda_function_name" {
  description = "Lambda function that starts the server on DNS query"
  value       = aws_lambda_function.start_server.function_name
}

output "world_data_volume_id" {
  description = "EBS volume ID for world data (back this up!)"
  value       = aws_ebs_volume.world_data.id
}

output "nameservers" {
  description = "Route53 nameservers to set at your registrar (only if a new zone was created)"
  value       = var.hosted_zone_id == "" ? aws_route53_zone.minecraft[0].name_servers : null
}
