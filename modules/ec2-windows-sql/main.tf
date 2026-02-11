# Find the latest Windows 2019 with SQL Server 2022 Standard AMI
data "aws_ami" "windows_sql_2022" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2019-English-Full-SQL_2022_Standard-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create key pair
resource "aws_key_pair" "windows_key" {
  key_name   = var.key_name
  public_key = tls_private_key.rsa.public_key_openssh
}

# Generate RSA key
resource "tls_private_key" "rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save private key to file
resource "local_file" "private_key" {
  content         = tls_private_key.rsa.private_key_pem
  filename        = "${var.key_name}.pem"
  file_permission = "0600"
}

# Security group for RDP access
resource "aws_security_group" "windows_sg" {
  name        = "windows-sql-sg"
  description = "Security group for Windows SQL Server"
  vpc_id      = var.vpc_id

  # RDP access from allowed IPs
  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
    description = "RDP access from allowed IPs"
  }

  # WinRM access from allowed IPs
  ingress {
    from_port   = 5985
    to_port     = 5985
    protocol    = "tcp"
    cidr_blocks = var.winrm_ips
    description = "WinRM access from WinRM IPs"
  }

  # WinRM HTTPS access
  ingress {
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = var.winrm_ips
    description = "WinRM HTTPS access"
  }

  # Outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "windows-sql-security-group"
  }
}

# EC2 instance
resource "aws_instance" "windows_sql_server" {
  ami               = data.aws_ami.windows_sql_2022.id
  instance_type     = var.instance_type
  subnet_id         = var.subnet_id
  key_name          = aws_key_pair.windows_key.key_name
  vpc_security_group_ids = [aws_security_group.windows_sg.id]
  user_data         = data.template_file.user_data.rendered
  iam_instance_profile = var.ec2_instance_role_arn != null ? var.ec2_instance_role_arn : null

  # Root block device with dynamic configuration
  root_block_device {
    volume_type = var.volume_type
    volume_size = var.volume_size
    iops        = var.iops > 0 ? var.iops : null
    throughput  = var.throughput > 0 ? var.throughput : null
    encrypted   = true
    
    tags = {
      Name = "${var.instance_name}-root-volume"
    }
  }

  tags = {
    Name = var.instance_name
  }

  # Get administrator password from AWS Systems Manager Parameter Store
  get_password_data = true
}

# User data template for AWS CLI installation and WinRM configuration
data "template_file" "user_data" {
  template = <<-EOF
<powershell>
# Set execution policy
Set-ExecutionPolicy RemoteSigned -Force

# Install AWS CLI
Write-Host "Installing AWS CLI..."
$awsCliUrl = "https://awscli.amazonaws.com/AWSCLIV2.msi"
$installerPath = "$env:TEMP\AWSCLIV2.msi"

# Download and install AWS CLI
Invoke-WebRequest -Uri $awsCliUrl -OutFile $installerPath
Start-Process msiexec.exe -Wait -ArgumentList "/i $installerPath /quiet /norestart"
Remove-Item $installerPath -Force

# Configure WinRM for remote management
Write-Host "Configuring WinRM..."

# Enable PSRemoting with proper authentication
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Configure WinRM service to start automatically
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# Configure WinRM for basic authentication (required for Packer/remote management)
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'

# Disable no authentication mode to avoid conflicts
winrm set winrm/config/service/auth '@{Negotiate="true"}'
winrm set winrm/config/service/auth '@{Certificate="false"}'

# Configure firewall rules for WinRM
netsh advfirewall firewall add rule name="WinRM HTTP" dir=in action=allow protocol=TCP localport=5985
netsh advfirewall firewall add rule name="WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986

# Set trusted hosts to allow connections from any host (for initial setup)
Set-Item WSMan:\localhost\Client\TrustedHosts "*" -Force

# Configure WinRM listener properly
winrm delete winrm/config/listener?Address=*+Transport=HTTP 2>$null
winrm create winrm/config/listener?Address=*+Transport=HTTP

# Configure service to allow remote access
winrm set winrm/config/service '@{EnableCompatibilityHttpListener="true"}'
winrm set winrm/config/service '@{EnableCompatibilityHttpsListener="true"}'

# Restart WinRM service to apply changes
Restart-Service WinRM -Force

# Verify WinRM configuration
Write-Host "WinRM configuration status:"
winrm enumerate winrm/config/listener
Write-Host "WinRM service status:"
Get-Service WinRM | Format-Table Name, Status, StartType
Write-Host "WinRM authentication settings:"
winrm get winrm/config/service/auth
winrm get winrm/config/client/auth

# Set environment variables for AWS CLI
[System.Environment]::SetEnvironmentVariable("AWS_DEFAULT_REGION", "${var.region}", [System.EnvironmentVariableTarget]::Machine)

Write-Host "AWS CLI installation and WinRM configuration completed successfully!"

# Test WinRM connectivity locally
try {
    $testResult = Test-WSMan -ErrorAction Stop
    Write-Host "WinRM self-test successful: $($testResult | Out-String)"
} catch {
    Write-Host "WinRM self-test failed: $_"
}

# Optional: Test AWS CLI installation
try {
    $awsVersion = aws --version
    Write-Host "AWS CLI Version: $awsVersion"
} catch {
    Write-Host "AWS CLI test failed: $_"
}

# Write completion marker
Write-Host "User data execution completed at $(Get-Date)"
</powershell>
EOF
}

# Output the decrypted password using AWS CLI (after instance creation)
resource "null_resource" "get_password" {
  depends_on = [aws_instance.windows_sql_server]

  triggers = {
    instance_id = aws_instance.windows_sql_server.id
  }

provisioner "local-exec" {
  interpreter = ["PowerShell", "-Command"]
  command = <<-EOT
    # Assume the IAM role and get temporary credentials
    $assumeRoleOutput = aws sts assume-role --role-arn "${var.terraform_role_arn}" --role-session-name "terraform-password-retrieval"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error assuming role: ${var.terraform_role_arn}"
        exit 1
    }
    
    # Parse the JSON response to extract credentials
    $credentials = $assumeRoleOutput | ConvertFrom-Json
    $env:AWS_ACCESS_KEY_ID = $credentials.Credentials.AccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $credentials.Credentials.SecretAccessKey
    $env:AWS_SESSION_TOKEN = $credentials.Credentials.SessionToken
    
    $maxAttempts = 20
    $attempt = 1
    $success = $false
    $delaySeconds = 30

    while ($attempt -le $maxAttempts -and -not $success) {
        Write-Host "Attempt $attempt of $maxAttempts to retrieve password..."
        
        try {
            $output = aws ec2 get-password-data `
              --instance-id ${aws_instance.windows_sql_server.id} `
              --priv-launch-key ${var.key_name}.pem `
              --region ${var.region} `
              --query PasswordData `
              --output text
            
            if (-not [string]::IsNullOrEmpty($output)) {
                $output | Out-File -FilePath "password.txt" -Encoding UTF8
                Write-Host "Password successfully retrieved and saved to password.txt"
                $success = $true
                break
            } else {
                Write-Host "Password data is empty, retrying in $delaySeconds seconds..."
            }
        }
        catch {
            Write-Host "Error retrieving password (Attempt $attempt): $($_.Exception.Message)"
        }
        
        if ($attempt -lt $maxAttempts -and -not $success) {
            Write-Host "Waiting $delaySeconds seconds before next attempt..."
            Start-Sleep -Seconds $delaySeconds
        }
        
        $attempt++
    }

    # Clean up environment variables
    $env:AWS_ACCESS_KEY_ID = $null
    $env:AWS_SECRET_ACCESS_KEY = $null
    $env:AWS_SESSION_TOKEN = $null

    if (-not $success) {
        Write-Host "Failed to retrieve password after $maxAttempts attempts. The instance may still be initializing."
        Write-Host "You can manually retrieve the password later using:"
        Write-Host "aws ec2 get-password-data --instance-id ${aws_instance.windows_sql_server.id} --priv-launch-key ${var.key_name}.pem --region ${var.region} --query PasswordData --output text"
        exit 1
    }
  EOT
}
}