output "instance_public_ip" {
  description = "Public IP address of the Windows SQL Server instance"
  value       = aws_instance.windows_sql_server.public_ip
}

output "instance_id" {
  description = "ID of the Windows SQL Server instance"
  value       = aws_instance.windows_sql_server.id
}

output "key_pair_name" {
  description = "Name of the generated key pair"
  value       = aws_key_pair.windows_key.key_name
}

output "rdp_connection_command" {
  description = "RDP connection command"
  value       = "mstsc /v:${aws_instance.windows_sql_server.public_ip}"
}

output "private_key_filename" {
  description = "Filename of the generated private key"
  value       = "${var.key_name}.pem"
  sensitive   = true
}