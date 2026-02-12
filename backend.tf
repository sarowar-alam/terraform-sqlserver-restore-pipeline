terraform {
  backend "s3" {
    bucket   = "terraform-state-bucket"           # Your existing S3 bucket name
    key      = "infrastructure/sql-server.tfstate"  # Your desired path/prefix
    region   = "us-east-1"              # Region where bucket exists
    encrypt  = true                     # Enable encryption (recommended)
  }
}