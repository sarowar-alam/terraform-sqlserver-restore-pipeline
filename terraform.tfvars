# AWS Configuration
ec2_instance_role_arn = "YOUR_EC2_INSTANCE_ROLE_ARN"
terraform_role_arn    = "arn:aws:iam::YOUR_TEST_ACCOUNT_ID:role/restore"
region      = "us-east-1"

# Security - REQUIRED: Replace with your actual IP
allowed_ips = ["YOUR_OFFICE_HOME_IP/32"]
winrm_ips = ["YOUR_GATEWAY_IP/32"]

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
