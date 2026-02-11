variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID"
  type        = string
}

variable "allowed_ips" {
  description = "List of allowed IP addresses for RDP access"
  type        = list(string)
}

variable "winrm_ips" {
  description = "List of allowed IP addresses for WinRM access"
  type        = list(string)
}

variable "ec2_instance_role_arn" {
  description = "ARN of an existing IAM role to attach to the EC2 instance (e.g., arn:aws:iam::123456789123:role/db-restore)"
  type        = string
  default     = null
}


variable "key_name" {
  description = "Name of the key pair"
  type        = string
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "volume_size" {
  description = "Root volume size in GiB"
  type        = number
}

variable "volume_type" {
  description = "Root volume type"
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "IOPS for the volume"
  type        = number
  default     = 0
}

variable "throughput" {
  description = "Throughput for the volume in MB/s"
  type        = number
  default     = 0
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "terraform_role_arn" {
  description = "ARN of the role for Terraform to assume for resource operations"
  type        = string
  default     = null
}