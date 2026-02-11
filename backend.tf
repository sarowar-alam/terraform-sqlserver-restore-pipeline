terraform {
  backend "s3" {
    bucket   = "YOUR_TF_STATE_BUCKET_NAME"           # Your existing S3 bucket name
    key      = "YOUR_PREFIX/sql-server.tfstate"  # Your desired path/prefix
    region   = "us-east-1"              # Region where bucket exists
    encrypt  = true                     # Enable encryption (recommended)
  }
}