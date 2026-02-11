# AWS Configuration
variable "aws_profile" {
  description = "AWS CLI profile name to use for backend operations"
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = null
}

variable "terraform_role_arn" {
  description = "ARN of the role for Terraform to assume for resource operations"
  type        = string
  default     = null
}


variable "ec2_instance_role_arn" {
  description = "ARN of an existing IAM role to attach to the EC2 instance"
  type        = string
  default     = null
}
# Networking
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# Security
variable "allowed_ips" {
  description = "List of allowed IP addresses for RDP access"
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.allowed_ips) > 0
    error_message = "At least one allowed IP must be specified for security reasons."
  }
}

variable "winrm_ips" {
  description = "List of allowed IP addresses for WinRM access"
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.winrm_ips) > 0
    error_message = "At least one allowed IP must be specified for security reasons."
  }
}

# EC2 Instance
variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "windows-sql-server"
}

variable "key_name" {
  description = "Name of the key pair"
  type        = string
  default     = "windows-sql-key"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.xlarge"
}

variable "volume_size" {
  description = "Root volume size in GiB"
  type        = number
  default     = 200
}

variable "volume_type" {
  description = "Root volume type"
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "IOPS for gp3 volume (0 means default)"
  type        = number
  default     = 3000
}

variable "throughput" {
  description = "Throughput for gp3 volume in MB/s (0 means default)"
  type        = number
  default     = 125
}