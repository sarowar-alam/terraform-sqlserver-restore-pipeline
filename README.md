# SQL Server Backup & Restore Automation Pipeline

> **Production-ready infrastructure-as-code solution for automated SQL Server backup validation, cross-account replication, and disaster recovery testing.**

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Repository Structure](#repository-structure)
- [Configuration](#configuration)
- [Deployment Guide](#deployment-guide)
- [Operations](#operations)
- [Development Workflow](#development-workflow)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Contributing](#contributing)

---

## Overview

This system automates SQL Server database backup validation and disaster recovery testing across AWS accounts. It orchestrates infrastructure provisioning, cross-account data transfer, database restoration, and validation reporting through a Jenkins-driven CI/CD pipeline.

### What This System Does

1. **Provisions ephemeral test infrastructure** – Spins up Windows Server 2019 + SQL Server 2022 on EC2 using Terraform
2. **Transfers backups across AWS accounts** – Securely copies latest database backups from production to test environments
3. **Restores and validates databases** – Performs automated restore operations and executes validation queries
4. **Compares test vs production** – Runs identical queries against both environments and reports discrepancies
5. **Notifies stakeholders** – Sends detailed HTML reports via AWS SES
6. **Cleans up automatically** – Tears down all resources after validation completes

### Key Benefits

- **Continuous DR validation** – Verify backup integrity on a schedule without manual intervention
- **Cost optimization** – Infrastructure exists only during test execution
- **Cross-account compliance** – Maintains production isolation while enabling testing
- **Audit trail** – Complete logging and email reporting for compliance
- **Reproducible environments** – Infrastructure-as-code ensures consistency

---

## Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         Jenkins Controller                        │
│  ┌──────────────┐  ┌────────────────┐  ┌──────────────────┐    │
│  │   Pipeline   │→ │   Terraform    │→ │   PowerShell     │    │
│  │   (Groovy)   │  │   Modules      │  │   Scripts        │    │
│  └──────────────┘  └────────────────┘  └──────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                               ↓
         ┌─────────────────────┴─────────────────────┐
         ↓                                             ↓
┌──────────────────────┐                    ┌──────────────────────┐
│  Source Account      │                    │  Destination Account │
│  (Production)        │                    │  (Test/DR)           │
│                      │                    │                      │
│  ┌────────────────┐ │                    │  ┌────────────────┐  │
│  │ S3 Bucket      │ │  ──Cross-Account─> │  │ S3 Bucket      │  │
│  │ (Backups)      │ │     IAM Assume     │  │ (Test)         │  │
│  └────────────────┘ │     Role           │  └────────────────┘  │
│                      │                    │         ↓            │
│  ┌────────────────┐ │                    │  ┌────────────────┐  │
│  │ SQL Production │ │                    │  │ EC2 Instance   │  │
│  │ Server         │ │                    │  │ SQL Server     │  │
│  └────────────────┘ │                    │  └────────────────┘  │
└──────────────────────┘                    └──────────────────────┘
```

### Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Orchestration** | Jenkins (Groovy DSL) | Pipeline execution, scheduling, parameters |
| **Infrastructure** | Terraform 1.0+ | Provision VPC, EC2, security groups |
| **Configuration Management** | PowerShell 5.1+ | Remote execution via WinRM |
| **Data Transfer** | Python 3.x + boto3 | Cross-account S3 operations |
| **Notifications** | AWS SES | Email reports with HTML formatting |
| **Compute** | AWS EC2 (t3.xlarge) | Windows Server 2019 + SQL Server 2022 |
| **Storage** | AWS S3 + EBS (gp3) | Backup storage and database volumes |

### Design Decisions

**Why ephemeral infrastructure?**  
- Reduces costs by only running during tests (~$0.50-2.00 per test run)
- Ensures clean state for each validation
- Eliminates configuration drift

**Why cross-account architecture?**  
- Production isolation and security
- Compliance with separation of duties
- Realistic DR scenario testing

**Why WinRM instead of SSM?**  
- Native Windows remote management
- Faster execution for multiple commands
- Simpler credential handling in Jenkins context

---

## Prerequisites

### Required Tools

Install these tools on your Jenkins server or local development machine:

#### 1. Terraform
```powershell
# Download and install Terraform 1.0+
choco install terraform  # Using Chocolatey
# OR download from: https://www.terraform.io/downloads

# Verify installation
terraform version  # Should show 1.0 or higher
```

#### 2. AWS CLI
```powershell
# Install AWS CLI v2
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi

# Verify installation
aws --version  # Should show aws-cli/2.x
```

#### 3. Python + boto3
```powershell
# Install Python 3.8+
choco install python

# Install required packages
pip install boto3 argparse

# Verify
python --version  # Should show 3.8+
python -c "import boto3; print(boto3.__version__)"
```

#### 4. PowerShell
```powershell
# Windows comes with PowerShell 5.1+
$PSVersionTable.PSVersion  # Should show 5.1 or higher
```

### AWS Account Setup

#### Required IAM Roles

**Source Account (Production):**
```json
{
  "RoleName": "source-account-role",
  "AssumeRolePolicyDocument": {
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::222222222222:role/dest-account-role"
      },
      "Action": "sts:AssumeRole"
    }]
  },
  "Policies": [{
    "PolicyName": "S3ReadAccess",
    "PolicyDocument": {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        "Resource": [
          "arn:aws:s3:::source-backups-bucket/*",
          "arn:aws:s3:::source-backups-bucket"
        ]
      }]
    }
  }]
}
```

**Destination Account (Test):**
```json
{
  "RoleName": "dest-account-role",
  "AssumeRolePolicyDocument": {
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }]
  },
  "Policies": [{
    "PolicyName": "S3AndEC2Access",
    "PolicyDocument": {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "s3:PutObject",
            "s3:GetObject",
            "s3:ListBucket"
          ],
          "Resource": [
            "arn:aws:s3:::dest-backups-bucket/*",
            "arn:aws:s3:::dest-backups-bucket"
          ]
        },
        {
          "Effect": "Allow",
          "Action": "sts:AssumeRole",
          "Resource": "arn:aws:iam::111111111111:role/source-account-role"
        }
      ]
    }
  }]
}
```

**Terraform Execution Role:**
```json
{
  "RoleName": "terraform-role",
  "Policies": [
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
    "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
  ]
}
```

#### S3 Bucket Configuration

**Source bucket policy (production account):**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::222222222222:role/dest-account-role"
    },
    "Action": [
      "s3:GetObject",
      "s3:ListBucket"
    ],
    "Resource": [
      "arn:aws:s3:::source-backups-bucket/*",
      "arn:aws:s3:::source-backups-bucket"
    ]
  }]
}
```

### Jenkins Setup

#### Required Jenkins Plugins
```bash
# Install these plugins via Jenkins UI or CLI
jenkins-cli install-plugin:
  - pipeline
  - credentials-binding
  - aws-credentials
  - git
  - pipeline-utility-steps
  - timestamper
```

#### Jenkins Credentials

Create these credentials in Jenkins (Credentials → Global → Add Credentials):

1. **AWS Access Keys for SES** (`aws-ses-credentials`)
   - Kind: Username with password
   - Username: AWS Access Key ID
   - Password: AWS Secret Access Key
   - Description: AWS credentials for SES email notifications

2. **GitHub SSH Key** (`jenkins-git-credentials`)
   - Kind: SSH Username with private key
   - ID: jenkins-git-credentials
   - Username: git
   - Private Key: Your SSH private key
   - Description: GitHub repository access

3. **SQL Server Production Credentials** (`sql-server-credentials`)
   - Kind: Username with password
   - Username: SQL Server username
   - Password: SQL Server password
   - Description: Production SQL Server credentials

#### Jenkins Agent Configuration

Ensure your Jenkins agent can access:
- AWS APIs (via IAM role or credentials)
- GitHub repositories (via SSH key)
- Target AWS accounts (via assumed roles)

### Network Requirements

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Jenkins Server | AWS API Endpoints | 443 | HTTPS | AWS API calls |
| Jenkins Server | GitHub | 22 | SSH | Repository cloning |
| Jenkins Server | EC2 Instance | 5985 | HTTP | WinRM (non-SSL) |
| Jenkins Server | EC2 Instance | 5986 | HTTPS | WinRM (SSL) |
| Jenkins Server | EC2 Instance | 3389 | RDP | Optional: manual troubleshooting |
| EC2 Instance | AWS S3 | 443 | HTTPS | Backup downloads |
| EC2 Instance | Production SQL | 1433 | TCP | Query validation |

---

## Quick Start

### 1. Clone Repository
```powershell
git clone git@github.com:user-1/automation-repo.git
cd terraform-sqlserver-restore-pipeline
```

### 2. Configure Variables
```powershell
# Copy example configuration
Copy-Item terraform.tfvars.example terraform.tfvars

# Edit with your values
notepad terraform.tfvars
```

Update these critical values:
```hcl
# AWS Configuration
ec2_instance_role_arn = "arn:aws:iam::222222222222:role/ec2-instance-role"
terraform_role_arn    = "arn:aws:iam::222222222222:role/terraform-role"
region                = "us-east-1"

# Security - REQUIRED: Replace with your actual IPs
allowed_ips = ["203.0.113.0/32"]  # Your office/VPN IP
winrm_ips   = ["203.0.113.0/32"]  # Jenkins server IP
```

### 3. Initialize Terraform Backend
```powershell
cd terraform
terraform init
```

### 4. Validate Configuration
```powershell
terraform validate
terraform plan
```

### 5. Configure Jenkins Pipeline

Create a new Pipeline job in Jenkins:

1. **New Item** → Enter name → **Pipeline** → OK
2. **Pipeline** section:
   - Definition: Pipeline script from SCM
   - SCM: Git
   - Repository URL: `git@github.com:user-1/automation-repo.git`
   - Script Path: `groovy/db-restore-test.gvy`
3. **Build Triggers** (optional):
   - Build periodically: `H 2 * * 1` (Weekly on Monday at 2 AM)
4. **Save**

### 6. Run First Test

1. Click **Build with Parameters**
2. Select:
   - TERRAFORM_ACTION: `Create`
   - DB_GLOBAL: `Database-A`
3. Click **Build**

Expected execution time: 15-25 minutes

---

## Repository Structure

```
terraform-sqlserver-restore-pipeline/
├── README.md                      # This file
├── backend.tf                     # Terraform S3 backend configuration
├── main.tf                        # Root Terraform configuration
├── variables.tf                   # Terraform variable definitions
├── terraform.tfvars              # Terraform variable values (customize this)
├── outputs.tf                     # Terraform outputs
├── providers.tf                   # Terraform provider configuration
│
├── modules/                       # Terraform modules
│   ├── vpc/                      # VPC infrastructure module
│   │   ├── main.tf               # VPC, subnets, IGW, route tables
│   │   ├── outputs.tf            # VPC and subnet IDs
│   │   └── variables.tf          # VPC CIDR configuration
│   │
│   └── ec2-windows-sql/          # EC2 SQL Server module
│       ├── main.tf               # EC2, security groups, AMI data
│       ├── outputs.tf            # Instance IP, RDP command
│       └── variables.tf          # Instance configuration
│
├── scripts/                       # Automation scripts
│   ├── add-trusted-host.ps1      # Add EC2 IP to WinRM trusted hosts
│   ├── remove-trusted-host.ps1   # Remove EC2 IP from trusted hosts
│   ├── download-s3-backup-remote.ps1  # Download backup to EC2
│   ├── download-transfer-db.py   # Cross-account S3 transfer (Python)
│   ├── download-transfer-db.ps1  # Cross-account S3 transfer (PowerShell)
│   ├── restore-db-sqlcmd.ps1     # Restore database using SQLCMD
│   ├── execute-query.ps1         # Run validation query on test DB
│   ├── execute-query-prod.ps1    # Run validation query on production
│   ├── last-monday.ps1           # Check if today is Monday (for scheduling)
│   └── sql-query.sql             # SQL validation query template
│
└── groovy/                        # Jenkins pipeline
    └── db-restore-test.gvy       # Main pipeline definition
```

### Key Files Explained

| File | Purpose | When to Modify |
|------|---------|----------------|
| `terraform.tfvars` | Infrastructure variables | Always (before first deployment) |
| `groovy/db-restore-test.gvy` | Pipeline logic | When changing workflow, adding databases |
| `scripts/sql-query.sql` | Validation query | When changing validation logic |
| `backend.tf` | Terraform state storage | Once during initial setup |
| `modules/*/main.tf` | Infrastructure definitions | When changing architecture |

---

## Configuration

### Terraform Variables Reference

Edit `terraform.tfvars` with these values:

```hcl
# ============================================
# AWS Configuration
# ============================================
region                = "us-east-1"
ec2_instance_role_arn = "arn:aws:iam::222222222222:role/ec2-instance-role"
terraform_role_arn    = "arn:aws:iam::222222222222:role/terraform-role"

# ============================================
# Networking
# ============================================
vpc_cidr           = "10.1.0.0/16"      # VPC CIDR block
public_subnet_cidr = "10.1.0.0/24"      # Public subnet CIDR

# ============================================
# Security - CRITICAL: Set Your IPs
# ============================================
allowed_ips = [
  "203.0.113.0/32",  # Office IP - RDP access
  "198.51.100.0/32"  # VPN IP - RDP access
]

winrm_ips = [
  "203.0.113.50/32"  # Jenkins server IP - WinRM access
]

# ============================================
# EC2 Instance Configuration
# ============================================
key_name      = "windows-sql-key"          # SSH key pair name (generated)
instance_name = "sql-restore-test-server"  # EC2 instance name tag
instance_type = "t3.xlarge"                # 4 vCPU, 16 GB RAM
volume_size   = 200                        # Root volume size (GB)
volume_type   = "gp3"                      # EBS volume type
iops          = 3000                       # IOPS for gp3
throughput    = 125                        # Throughput (MB/s) for gp3
```

### Pipeline Environment Variables

Edit `groovy/db-restore-test.gvy` if you need to customize:

```groovy
environment {
    AWS_REGION = 'us-east-1'
    
    // Source account (production backups)
    SOURCE_ROLE_ARN = "arn:aws:iam::111111111111:role/source-account-role"
    SOURCE_BUCKET = "source-backups-bucket"
    SOURCE_PREFIX = "database-backups/"
    
    // Destination account (test environment)
    DEST_ROLE_ARN = "arn:aws:iam::222222222222:role/dest-account-role"
    DEST_BUCKET = "dest-backups-bucket"
    DEST_PREFIX = "restored-backups/"
    
    // Production SQL Server for validation queries
    PROD_SQL_IP = "10.0.100.50"
    
    // Local directory on EC2 for backups
    REMOTE_LOCAL_DIR = "C:\\DBBackups\\"
}
```

### Database Configuration

Add or modify databases in `groovy/db-restore-test.gvy`:

```groovy
def DB_CHOICES = [
    'Database-A',
    'Database-B',
    'Database-C',
    'Database-D'  // Add new databases here
]
```

### Email Notification Recipients

Update email recipients in the pipeline:

```groovy
// In sendResultsEmail function
def toRecipients = "'user-1@company-a.com', 'user-2@company-a.com'"
def ccRecipients = "'manager@company-a.com', 'team@company-a.com'"
```

---

## Deployment Guide

### Initial Setup (One-Time)

#### 1. Configure AWS Backend

Initialize Terraform state backend:

```powershell
# Update backend.tf with your S3 bucket
terraform {
  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "infrastructure/sql-server.tfstate"
    region = "us-east-1"
  }
}

# Initialize
cd terraform
terraform init
```

#### 2. Create S3 Buckets

```powershell
# Source account (production)
aws s3 mb s3://source-backups-bucket --region us-east-1

# Destination account (test)
aws s3 mb s3://dest-backups-bucket --region us-east-1
aws s3 mb s3://terraform-state-bucket --region us-east-1

# Enable versioning for state bucket
aws s3api put-bucket-versioning \
    --bucket terraform-state-bucket \
    --versioning-configuration Status=Enabled
```

#### 3. Configure SES Email

```powershell
# Verify sender email
aws ses verify-email-identity --email-address noreply@company-a.com

# Verify recipient emails (if in sandbox)
aws ses verify-email-identity --email-address user-1@company-a.com

# Check verification status
aws ses get-identity-verification-attributes \
    --identities noreply@company-a.com
```

#### 4. Test Terraform Configuration

```powershell
# Validate configuration
terraform validate

# Plan deployment
terraform plan

# Expected output: Will create ~10 resources
# - VPC, Subnet, IGW, Route Table, Security Groups
# - EC2 Instance, Key Pair, IAM profiles
```

### Standard Deployment

#### Via Jenkins (Recommended)

1. **Navigate to Jenkins job**
2. **Click "Build with Parameters"**
3. **Select options:**
   - TERRAFORM_ACTION: `Create`
   - DB_GLOBAL: Choose database
4. **Click "Build"**
5. **Monitor console output**

#### Manual Deployment (Terraform)

```powershell
# Navigate to repository root
cd terraform-sqlserver-restore-pipeline

# Plan infrastructure
terraform plan -var-file="terraform.tfvars"

# Apply configuration
terraform apply -var-file="terraform.tfvars" -auto-approve

# Capture outputs
terraform output -json > outputs.json

# Extract instance IP
$outputs = Get-Content outputs.json | ConvertFrom-Json
$instanceIP = $outputs.instance_public_ip.value
Write-Host "Instance IP: $instanceIP"
```

#### Manual Deployment (Full Pipeline)

```powershell
# 1. Deploy infrastructure
terraform apply -auto-approve

# 2. Get instance IP and password
$instanceIP = terraform output -raw instance_public_ip
$password = Get-Content password.txt

# 3. Add to trusted hosts
.\scripts\add-trusted-host.ps1 -IPAddress $instanceIP

# 4. Transfer backup across accounts
python .\scripts\download-transfer-db.py `
    --source-role-arn "arn:aws:iam::111111111111:role/source-account-role" `
    --source-bucket "source-backups-bucket" `
    --source-prefix "database-backups/Database-A" `
    --dest-role-arn "arn:aws:iam::222222222222:role/dest-account-role" `
    --dest-bucket "dest-backups-bucket" `
    --dest-prefix "restored-backups/"

# 5. Download to EC2 (run remotely via WinRM)
.\scripts\download-s3-backup-remote.ps1 `
    -RemoteServer $instanceIP `
    -Username "administrator" `
    -S3BucketName "dest-backups-bucket" `
    -S3Prefix "restored-backups/" `
    -DBName "Database-A" `
    -RemoteDirectory "C:\DBBackups\"

# 6. Restore database
.\scripts\restore-db-sqlcmd.ps1 `
    -RemoteServerIP $instanceIP `
    -Username "administrator" `
    -RemoteFolderPath "C:\DBBackups" `
    -FilePrefix "Database-A" `
    -DatabaseName "Database-A"

# 7. Run validation query
.\scripts\execute-query.ps1 `
    -RemoteServerIP $instanceIP `
    -Username "administrator" `
    -RemoteFolderPath "C:\DBBackups" `
    -SQLFilePath ".\scripts\sql-query.sql" `
    -DatabaseName "Database-A"

# 8. Cleanup
.\scripts\remove-trusted-host.ps1 -IPAddress $instanceIP
terraform destroy -auto-approve
```

### Scheduled Deployment

Configure Jenkins to run automatically:

**Option 1: Cron Schedule**
```groovy
triggers {
    cron('H 2 * * 1')  // Every Monday at 2 AM
}
```

**Option 2: Webhook Trigger**
```groovy
triggers {
    githubPush()  // Trigger on repository push
}
```

**Option 3: Upstream Job**
```groovy
triggers {
    upstream(upstreamProjects: 'backup-job', threshold: hudson.model.Result.SUCCESS)
}
```

---

## Operations

### Common Tasks

#### View Running Infrastructure

```powershell
# List EC2 instances
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=sql-restore-test-server" \
    --query "Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]" \
    --output table

# Check Terraform state
terraform show

# Get current outputs
terraform output
```

#### Access EC2 Instance

**Via RDP:**
```powershell
# Get connection details
terraform output rdp_connection_command

# Connect
mstsc /v:203.0.113.100
# Username: administrator
# Password: (from password.txt file)
```

**Via WinRM (PowerShell):**
```powershell
# Create credential
$password = ConvertTo-SecureString (Get-Content password.txt) -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("administrator", $password)

# Connect
$session = New-PSSession -ComputerName 203.0.113.100 -Credential $credential

# Run commands
Invoke-Command -Session $session -ScriptBlock {
    Get-Service MSSQLSERVER
    Get-ChildItem C:\DBBackups
}

# Disconnect
Remove-PSSession $session
```

#### Monitor Pipeline Execution

**Jenkins Console:**
1. Navigate to job
2. Click on build number (#123)
3. Click "Console Output"
4. Monitor real-time logs

**Key stages to watch:**
- ✅ EC2Deploy (~5-8 minutes)
- ✅ DownloadTransferDB (~2-5 minutes)
- ✅ DownloadDBRemote (~3-10 minutes depending on backup size)
- ✅ RestoreDatabase (~2-5 minutes)
- ✅ ExecuteQueryDatabase (~1-2 minutes)

#### Check Backup Status

```powershell
# List backups in source bucket
aws s3 ls s3://source-backups-bucket/database-backups/Database-A/ --recursive

# List backups in destination bucket
aws s3 ls s3://dest-backups-bucket/restored-backups/ --recursive

# Get latest backup info
aws s3api list-objects-v2 \
    --bucket source-backups-bucket \
    --prefix database-backups/Database-A/ \
    --query 'reverse(sort_by(Contents, &LastModified))[0]'
```

#### Validate Email Notifications

```powershell
# Check SES sending statistics
aws ses get-send-statistics

# List verified email addresses
aws ses list-verified-email-addresses

# Check if email is verified
aws ses get-identity-verification-attributes \
    --identities user-1@company-a.com
```

### Emergency Procedures

#### Abort Running Pipeline

1. Navigate to Jenkins job
2. Click red "X" next to running build
3. Confirm termination
4. Manually cleanup infrastructure:

```powershell
cd terraform
terraform destroy -auto-approve
```

#### Force Cleanup of Stuck Resources

```powershell
# Find and terminate EC2 instances
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=sql-restore-test-server" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text | ForEach-Object {
        aws ec2 terminate-instances --instance-ids $_
    }

# Delete VPC (after instances terminated)
$vpcId = aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=windows-sql-vpc" \
    --query "Vpcs[0].VpcId" \
    --output text

if ($vpcId -ne "None") {
    # Delete dependencies first
    aws ec2 delete-subnet --subnet-id (aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[0].SubnetId" --output text)
    aws ec2 detach-internet-gateway --internet-gateway-id (aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --query "InternetGateways[0].InternetGatewayId" --output text) --vpc-id $vpcId
    aws ec2 delete-internet-gateway --internet-gateway-id (aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --query "InternetGateways[0].InternetGatewayId" --output text)
    aws ec2 delete-vpc --vpc-id $vpcId
}

# Remove WinRM trusted hosts
.\scripts\remove-trusted-host.ps1 -IPAddress "203.0.113.100"
```

#### Recover from Failed Restore

```powershell
# 1. Connect to EC2 instance
$instanceIP = "203.0.113.100"
$session = New-PSSession -ComputerName $instanceIP -Credential $credential

# 2. Check SQL Server status
Invoke-Command -Session $session -ScriptBlock {
    Get-Service MSSQLSERVER
    
    # Restart if needed
    Restart-Service MSSQLSERVER -Force
}

# 3. Check backup files
Invoke-Command -Session $session -ScriptBlock {
    Get-ChildItem C:\DBBackups\*.BAK | Select-Object Name, Length, LastWriteTime
}

# 4. Manually restore database
Invoke-Command -Session $session -ScriptBlock {
    param($dbName, $backupFile)
    
    sqlcmd -S localhost -Q "RESTORE DATABASE [$dbName] FROM DISK = N'$backupFile' WITH REPLACE, RECOVERY"
} -ArgumentList "Database-A", "C:\DBBackups\Database-A_20260212.BAK"

# 5. Verify database online
Invoke-Command -Session $session -ScriptBlock {
    sqlcmd -S localhost -Q "SELECT name, state_desc FROM sys.databases WHERE name = 'Database-A'"
}
```

### Monitoring and Alerts

#### CloudWatch Metrics to Monitor

```powershell
# EC2 CPU utilization
aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value=i-1234567890abcdef0 \
    --start-time 2026-02-12T00:00:00Z \
    --end-time 2026-02-12T23:59:59Z \
    --period 3600 \
    --statistics Average

# VPC Flow Logs (if enabled)
aws ec2 describe-flow-logs \
    --filter "Name=resource-id,Values=vpc-12345678"
```

#### Set Up CloudWatch Alarms

```powershell
# CPU alarm for EC2
aws cloudwatch put-metric-alarm \
    --alarm-name sql-restore-high-cpu \
    --alarm-description "Alert when CPU exceeds 90%" \
    --metric-name CPUUtilization \
    --namespace AWS/EC2 \
    --statistic Average \
    --period 300 \
    --threshold 90 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --dimensions Name=InstanceId,Value=i-1234567890abcdef0
```

---

## Development Workflow

### Local Development Setup

#### 1. Fork and Clone
```bash
git clone git@github.com:your-username/terraform-sqlserver-restore-pipeline.git
cd terraform-sqlserver-restore-pipeline
git remote add upstream git@github.com:user-1/automation-repo.git
```

#### 2. Create Feature Branch
```bash
git checkout -b feature/add-new-database
```

#### 3. Make Changes

**Adding a new database:**
```groovy
// Edit groovy/db-restore-test.gvy
def DB_CHOICES = [
    'Database-A',
    'Database-B',
    'Database-C',
    'Database-D'  // Your new database
]
```

**Modifying SQL validation query:**
```sql
-- Edit scripts/sql-query.sql
SELECT 
    COUNT(*) AS TotalRecords,
    MAX(ModifiedDate) AS LastModified
FROM 
    YourTable
WHERE 
    IsActive = 1;
```

**Adjusting infrastructure:**
```hcl
// Edit terraform.tfvars
instance_type = "t3.2xlarge"  // Increase for larger databases
volume_size   = 500          // Increase storage
```

#### 4. Test Changes Locally

**Test Terraform:**
```powershell
cd terraform
terraform init
terraform validate
terraform plan
```

**Test PowerShell scripts:**
```powershell
# Use Pester for unit tests
Install-Module -Name Pester -Force

# Run tests
Invoke-Pester -Path .\tests\
```

**Test Python scripts:**
```powershell
# Install dev dependencies
pip install pytest boto3 moto

# Run tests
pytest tests/
```

#### 5. Commit and Push
```bash
git add .
git commit -m "feat: add Database-D support and validation query"
git push origin feature/add-new-database
```

#### 6. Create Pull Request
1. Navigate to GitHub
2. Click "New Pull Request"
3. Select your branch
4. Fill out PR template
5. Request review

### Testing Strategy

#### Unit Tests

**PowerShell (Pester):**
```powershell
# tests/add-trusted-host.Tests.ps1
Describe "Add-TrustedHost" {
    It "Should add IP to trusted hosts" {
        Mock Get-Item { @{ Value = "" } }
        Mock Set-Item { }
        
        .\scripts\add-trusted-host.ps1 -IPAddress "10.0.0.1"
        
        Assert-MockCalled Set-Item -Times 1
    }
}
```

**Python (pytest):**
```python
# tests/test_download_transfer.py
import pytest
from unittest.mock import Mock, patch
from scripts.download_transfer_db import assume_role

def test_assume_role_success():
    with patch('boto3.client') as mock_client:
        mock_sts = Mock()
        mock_sts.assume_role.return_value = {
            'Credentials': {
                'AccessKeyId': 'test',
                'SecretAccessKey': 'test',
                'SessionToken': 'test'
            }
        }
        mock_client.return_value = mock_sts
        
        result = assume_role('arn:aws:iam::123456789012:role/test')
        
        assert result['AccessKeyId'] == 'test'
```

#### Integration Tests

**Test full pipeline flow:**
```powershell
# tests/integration/test-pipeline.ps1

# 1. Deploy infrastructure
terraform apply -auto-approve -var="instance_type=t3.medium"

# 2. Wait for instance ready
Start-Sleep -Seconds 300

# 3. Run backup transfer
python .\scripts\download-transfer-db.py --source-role-arn $sourceRole ...

# 4. Verify backup downloaded
$backupExists = Invoke-Command -Session $session -ScriptBlock {
    Test-Path "C:\DBBackups\*.BAK"
}

# 5. Cleanup
terraform destroy -auto-approve

# Assert
if (-not $backupExists) {
    throw "Integration test failed: Backup not found"
}
```

### Code Quality Standards

#### Terraform
```hcl
# Use consistent formatting
terraform fmt -recursive

# Validate syntax
terraform validate

# Security scanning
tfsec .

# Cost estimation
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan | infracost breakdown --path=-
```

#### PowerShell
```powershell
# Install PSScriptAnalyzer
Install-Module -Name PSScriptAnalyzer -Force

# Run linter
Invoke-ScriptAnalyzer -Path .\scripts\ -Recurse

# Check for best practices
Invoke-ScriptAnalyzer -Path .\scripts\ -Severity Warning,Error
```

#### Python
```python
# Install tools
pip install black flake8 pylint mypy

# Format code
black scripts/

# Lint
flake8 scripts/ --max-line-length=100
pylint scripts/

# Type checking
mypy scripts/
```

### CI/CD Integration

**GitHub Actions example:**
```yaml
name: Validate Terraform

on: [push, pull_request]

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v1
        
      - name: Terraform Format
        run: terraform fmt -check -recursive
        
      - name: Terraform Init
        run: terraform init
        
      - name: Terraform Validate
        run: terraform validate
        
      - name: Terraform Plan
        run: terraform plan
```

---

## Troubleshooting

### Common Issues

#### Issue: Terraform Apply Fails with "InvalidAMIID.NotFound"

**Symptom:**
```
Error: creating EC2 Instance: InvalidAMIID.NotFound: The image id '[ami-xxxxx]' does not exist
```

**Cause:** AMI not available in selected region

**Resolution:**
```powershell
# Check available SQL Server AMIs in your region
aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=Windows_Server-2019-English-Full-SQL_2022_Standard-*" \
    --query 'Images[*].[ImageId,Name,CreationDate]' \
    --output table \
    --region us-east-1

# Update modules/ec2-windows-sql/main.tf if needed
```

#### Issue: WinRM Connection Fails

**Symptom:**
```
Connecting to remote server 203.0.113.100 failed with the following error message:
WinRM cannot complete the operation
```

**Resolution:**
```powershell
# 1. Check security group rules
aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=windows-sql-security-group" \
    --query "SecurityGroups[0].IpPermissions"

# 2. Verify trusted hosts
Get-Item WSMan:\localhost\Client\TrustedHosts

# 3. Test connectivity
Test-NetConnection -ComputerName 203.0.113.100 -Port 5985

# 4. Check WinRM service on EC2 (via RDP)
Get-Service WinRM
winrm get winrm/config

# 5. Re-add to trusted hosts
.\scripts\add-trusted-host.ps1 -IPAddress "203.0.113.100"
```

#### Issue: Database Restore Fails

**Symptom:**
```
Msg 3201, Level 16, State 2: Cannot open backup device
```

**Resolution:**
```powershell
# 1. Connect to EC2
$session = New-PSSession -ComputerName $instanceIP -Credential $cred

# 2. Check backup file
Invoke-Command -Session $session -ScriptBlock {
    Get-ChildItem C:\DBBackups\*.BAK | Format-List FullName, Length
    
    # Check file integrity
    RESTORE HEADERONLY FROM DISK = 'C:\DBBackups\Database-A.BAK'
}

# 3. Check SQL Server permissions
Invoke-Command -Session $session -ScriptBlock {
    $acl = Get-Acl "C:\DBBackups"
    $acl.Access | Where-Object {$_.IdentityReference -like "*SQL*"}
}

# 4. Grant permissions if needed
Invoke-Command -Session $session -ScriptBlock {
    $acl = Get-Acl "C:\DBBackups"
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT SERVICE\MSSQLSERVER", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.SetAccessRule($rule)
    Set-Acl "C:\DBBackups" $acl
}
```

#### Issue: Cross-Account S3 Transfer Fails

**Symptom:**
```
An error occurred (AccessDenied) when calling the AssumeRole operation
```

**Resolution:**
```powershell
# 1. Verify IAM role trust relationship
aws iam get-role --role-name dest-account-role \
    --query 'Role.AssumeRolePolicyDocument'

# 2. Test assume role manually
aws sts assume-role \
    --role-arn arn:aws:iam::222222222222:role/dest-account-role \
    --role-session-name test

# 3. Check S3 bucket policy
aws s3api get-bucket-policy \
    --bucket source-backups-bucket

# 4. Verify source bucket allows cross-account access
aws s3api get-bucket-policy \
    --bucket source-backups-bucket | \
    jq '.Policy | fromjson | .Statement[] | select(.Effect=="Allow" and .Principal.AWS != null)'
```

#### Issue: Email Notifications Not Received

**Symptom:** Pipeline completes but no email arrives

**Resolution:**
```powershell
# 1. Check SES sending quota
aws ses get-send-quota

# 2. Verify email addresses
aws ses list-verified-email-addresses

# 3. Check if in SES sandbox
aws ses get-account-sending-enabled

# 4. Request production access
# Go to AWS Console → SES → Account Dashboard → Request Production Access

# 5. Check spam folder

# 6. View SES send statistics
aws ses get-send-statistics
```

#### Issue: Terraform State Lock

**Symptom:**
```
Error: Error acquiring the state lock
Lock Info:
  ID:        abc123...
  Path:      terraform-state-bucket/infrastructure/sql-server.tfstate
```

**Resolution:**
```powershell
# Option 1: Wait for lock to release (if another operation is running)

# Option 2: Force unlock (DANGEROUS - only if you're sure no other operation is running)
terraform force-unlock abc123

# Option 3: Check DynamoDB lock table (if using DynamoDB for locking)
aws dynamodb scan --table-name terraform-locks

# Prevention: Enable state locking with DynamoDB
# Add to backend.tf:
terraform {
  backend "s3" {
    bucket         = "terraform-state-bucket"
    key            = "infrastructure/sql-server.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

### Debugging Tips

#### Enable Verbose Logging

**Terraform:**
```powershell
$env:TF_LOG = "DEBUG"
$env:TF_LOG_PATH = "terraform-debug.log"
terraform apply
```

**PowerShell:**
```powershell
# Enable transcript
Start-Transcript -Path "script-debug.log"

# Run script with verbose output
.\scripts\restore-db-sqlcmd.ps1 -Verbose

Stop-Transcript
```

**Python:**
```python
# Add to scripts
import logging
logging.basicConfig(level=logging.DEBUG)
```

#### Inspect Infrastructure State

```powershell
# View complete Terraform state
terraform show

# Query specific resources
terraform state list
terraform state show aws_instance.windows_sql_server

# Export state to JSON
terraform show -json | Out-File state.json
```

#### Check Jenkins Build Logs

```groovy
// Add debugging to pipeline
stage('Debug') {
    steps {
        script {
            echo "Environment Variables:"
            bat "set"
            
            echo "AWS Identity:"
            bat "aws sts get-caller-identity"
            
            echo "Terraform Version:"
            bat "terraform version"
        }
    }
}
```

---

## Security Considerations

### Secrets Management

**Never commit secrets to Git:**
```bash
# Add to .gitignore
*.tfvars
password.txt
*.pem
*.key
*.credentials
.env
```

**Use Jenkins Credentials:**
- Store AWS keys, SQL passwords, SSH keys in Jenkins credential store
- Reference via `withCredentials` binding
- Rotate regularly (quarterly minimum)

**Terraform Sensitive Variables:**
```hcl
variable "admin_password" {
  type      = string
  sensitive = true
}
```

### Network Security

**Security Group Best Practices:**
```hcl
# Restrict RDP to specific IPs only
ingress {
  from_port   = 3389
  to_port     = 3389
  protocol    = "tcp"
  cidr_blocks = ["203.0.113.0/32"]  # Your IP only
  description = "RDP from authorized IP"
}

# Restrict WinRM to Jenkins servers only
ingress {
  from_port   = 5985
  to_port     = 5985
  protocol    = "tcp"
  cidr_blocks = ["203.0.113.50/32"]  # Jenkins IP only
  description = "WinRM from Jenkins"
}
```

**VPC Flow Logs (optional but recommended):**
```powershell
aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids vpc-12345678 \
    --traffic-type ALL \
    --log-destination-type cloud-watch-logs \
    --log-group-name /aws/vpc/flowlogs
```

### IAM Least Privilege

**Service-specific roles:**
- EC2 instance role: S3 read/write to specific buckets only
- Terraform role: EC2/VPC/IAM read/write in test account only
- Lambda functions: Only permissions they need

**Example least-privilege policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::dest-backups-bucket",
        "arn:aws:s3:::dest-backups-bucket/*"
      ],
      "Condition": {
        "StringLike": {
          "s3:prefix": ["restored-backups/*"]
        }
      }
    }
  ]
}
```

### Data Protection

**Encryption at rest:**
- S3 buckets: Enable SSE-S3 or SSE-KMS
- EBS volumes: Encrypted by default in Terraform
- RDS backups: Encrypted

**Encryption in transit:**
- S3 transfers: HTTPS only
- WinRM: Configure for HTTPS (port 5986)
- SQL connections: Encrypt=yes in connection strings

**Backup retention:**
```powershell
# Configure S3 lifecycle policy for automatic cleanup
aws s3api put-bucket-lifecycle-configuration \
    --bucket dest-backups-bucket \
    --lifecycle-configuration file://lifecycle.json

# lifecycle.json:
{
  "Rules": [{
    "Id": "DeleteOldBackups",
    "Status": "Enabled",
    "Prefix": "restored-backups/",
    "Expiration": {
      "Days": 7
    }
  }]
}
```

### Compliance and Auditing

**Enable CloudTrail:**
```powershell
aws cloudtrail create-trail \
    --name sql-restore-audit \
    --s3-bucket-name audit-logs-bucket

aws cloudtrail start-logging --name sql-restore-audit
```

**Tag all resources:**
```hcl
tags = {
  Environment = "Test"
  Project     = "SQL-Restore-Automation"
  ManagedBy   = "Terraform"
  CostCenter  = "Infrastructure"
  Owner       = "DevOps-Team"
}
```

**Review access logs:**
```powershell
# S3 access logs
aws s3api get-bucket-logging --bucket dest-backups-bucket

# Enable if not already
aws s3api put-bucket-logging \
    --bucket dest-backups-bucket \
    --bucket-logging-status file://logging.json
```

---

## Contributing

### Pull Request Process

1. **Create feature branch** from `main`
2. **Make changes** following code standards
3. **Test thoroughly** (unit + integration tests)
4. **Update documentation** if needed
5. **Submit PR** with clear description
6. **Address review feedback**
7. **Squash and merge** after approval

### Commit Message Convention

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

**Examples:**
```
feat(terraform): add support for SQL Server 2019

- Update AMI filters to include SQL 2019
- Add version parameter to variables
- Update documentation

Closes #123
```

### Code Review Checklist

- [ ] Code follows style guidelines
- [ ] Tests added/updated and passing
- [ ] Documentation updated
- [ ] No secrets committed
- [ ] Terraform plan successful
- [ ] No breaking changes (or documented)
- [ ] Security implications considered

---

## License

This project is licensed under the MIT License - see LICENSE file for details.

---

## Support

### Getting Help

- **Documentation**: This README and inline code comments
- **Issues**: [GitHub Issues](https://github.com/user-1/automation-repo/issues)
- **Email**: user-1@company-a.com
- **Slack**: #infrastructure-automation (internal)

### Reporting Bugs

Include in bug reports:
1. Steps to reproduce
2. Expected vs actual behavior
3. Jenkins console output
4. Terraform plan/apply output
5. Environment details (OS, versions, etc.)

### Feature Requests

Use GitHub Issues with:
1. Use case description
2. Proposed solution
3. Alternative approaches considered
4. Impact on existing functionality

---

## Changelog

### v1.0.0 (2026-02-12)
- Initial production release
- Full automation of backup validation
- Cross-account S3 transfer
- Email notifications
- Comprehensive documentation

---

**Maintained by**: DevOps Team, Company-A  
**Last Updated**: February 12, 2026