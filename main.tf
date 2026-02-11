module "vpc" {
  source = "./modules/vpc"

  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  region             = var.region
}

module "windows_sql_server" {
  source = "./modules/ec2-windows-sql"

  vpc_id             = module.vpc.vpc_id
  subnet_id          = module.vpc.public_subnet_id
  allowed_ips        = var.allowed_ips
  winrm_ips          = var.winrm_ips
  key_name           = var.key_name
  instance_name      = var.instance_name
  instance_type      = var.instance_type
  volume_size        = var.volume_size
  volume_type        = var.volume_type
  iops               = var.iops
  throughput         = var.throughput
  region             = var.region
  terraform_role_arn = var.terraform_role_arn
  ec2_instance_role_arn = var.ec2_instance_role_arn

}