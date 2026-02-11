output "instance_public_ip" {
  description = "Public IP address of the Windows SQL Server instance"
  value       = module.windows_sql_server.instance_public_ip
}

output "rdp_connection_command" {
  description = "RDP connection command"
  value       = module.windows_sql_server.rdp_connection_command
}

output "key_pair_name" {
  description = "Name of the generated key pair"
  value       = module.windows_sql_server.key_pair_name
}

output "vpc_id" {
  description = "ID of the created VPC"
  value       = module.vpc.vpc_id
}