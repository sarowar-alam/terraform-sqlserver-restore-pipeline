# AWS Configuration
ec2_instance_role_arn = "arn:aws:iam::222222222222:role/ec2-instance-role"
terraform_role_arn    = "arn:aws:iam::222222222222:role/terraform-role"
region      = "us-east-1"

# Security - REQUIRED: Replace with your actual IP
allowed_ips = ["203.0.113.0/32"]
winrm_ips = ["203.0.113.0/32"]

# Networking
vpc_cidr           = "10.1.0.0/16"
public_subnet_cidr = "10.1.0.0/24"

# EC2 Instance
key_name      = "windows-sql-key"
instance_name = "windows-sql-server-2022"
instance_type = "t3.xlarge"
volume_size   = 200
volume_type   = "gp3"
iops          = 3000
throughput    = 125
