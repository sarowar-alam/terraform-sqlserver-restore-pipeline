import boto3
import os
import logging
import argparse
import tempfile
import winrm
import json
from botocore.exceptions import ClientError, NoCredentialsError, EndpointConnectionError
import time

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def assume_role(role_arn, session_name="S3Session"):
    """
    Assume an IAM role and return credentials
    """
    try:
        logger.info(f"Assuming IAM role: {role_arn}")
        sts_client = boto3.client('sts')
        assumed_role = sts_client.assume_role(
            RoleArn=role_arn,
            RoleSessionName=session_name
        )
        credentials = assumed_role['Credentials']
        logger.info("Successfully assumed IAM role")
        return credentials
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_msg = e.response['Error']['Message']
        logger.error(f"Failed to assume role {role_arn}: {error_code} - {error_msg}")
        raise Exception(f"Failed to assume role: {error_code} - {error_msg}")

def create_s3_client(credentials):
    """
    Create S3 client with given credentials
    """
    return boto3.client(
        's3',
        aws_access_key_id=credentials['AccessKeyId'],
        aws_secret_access_key=credentials['SecretAccessKey'],
        aws_session_token=credentials['SessionToken']
    )

def download_last_modified_object(role_arn, bucket_name, prefix, local_dir):
    """
    Find and download the last modified object from S3 prefix
    """
    s3_client = None
    try:
        logger.info(f"Starting process to download last modified object from s3://{bucket_name}/{prefix}")
        
        # Validate inputs
        if not all([role_arn, bucket_name, prefix, local_dir]):
            raise ValueError("Missing required parameters: role_arn, bucket_name, prefix, and local_dir are all required")
        
        if not role_arn.startswith('arn:aws:iam::'):
            raise ValueError(f"Invalid role ARN format: {role_arn}")
        
        # Create local directory if it doesn't exist
        logger.info(f"Ensuring local directory exists: {local_dir}")
        os.makedirs(local_dir, exist_ok=True)
        
        if not os.path.isdir(local_dir):
            raise OSError(f"Failed to create or access directory: {local_dir}")
        
        # Assume the IAM role and create S3 client
        credentials = assume_role(role_arn, "S3DownloadSession")
        s3_client = create_s3_client(credentials)
        
        # List objects in the prefix with pagination
        logger.info(f"Listing objects in s3://{bucket_name}/{prefix}")
        paginator = s3_client.get_paginator('list_objects_v2')
        page_iterator = paginator.paginate(Bucket=bucket_name, Prefix=prefix)
        
        latest_object = None
        object_count = 0
        
        for page_num, page in enumerate(page_iterator, 1):
            if 'Contents' in page:
                object_count += len(page['Contents'])
                for obj in page['Contents']:
                    if latest_object is None or obj['LastModified'] > latest_object['LastModified']:
                        latest_object = obj
                logger.info(f"Processed page {page_num}, found {len(page['Contents'])} objects")
        
        if latest_object is None:
            raise Exception(f"No objects found in prefix: s3://{bucket_name}/{prefix}")
        
        logger.info(f"Found {object_count} total objects. Latest object: {latest_object['Key']}")
        logger.info(f"Last modified: {latest_object['LastModified']}, Size: {latest_object['Size']} bytes")
        
        object_key = latest_object['Key']
        object_name = os.path.basename(object_key)
        local_path = os.path.join(local_dir, object_name)
        
        # Check if file already exists
        if os.path.exists(local_path):
            logger.warning(f"File already exists at {local_path}, it will be overwritten")
        
        # Download the object
        logger.info(f"Downloading {object_key} to {local_path}...")
        s3_client.download_file(bucket_name, object_key, local_path)
        
        # Verify download
        if os.path.exists(local_path):
            file_size = os.path.getsize(local_path)
            logger.info(f"Successfully downloaded: {local_path} (Size: {file_size} bytes)")
            return local_path, object_name
        else:
            raise Exception(f"Download failed: File not found at {local_path}")
            
    except Exception as e:
        logger.error(f"Download error: {str(e)}")
        raise

def upload_to_destination_s3(role_arn, bucket_name, prefix, local_file_path):
    """
    Upload a file to destination S3 bucket
    """
    s3_client = None
    try:
        credentials = assume_role(role_arn, "S3UploadSession")
        s3_client = create_s3_client(credentials)
        
        # Extract filename and construct destination key
        filename = os.path.basename(local_file_path)
        destination_key = f"{prefix.rstrip('/')}/{filename}" if prefix else filename
        
        # Upload the file
        logger.info(f"Uploading {local_file_path} to s3://{bucket_name}/{destination_key}")
        s3_client.upload_file(local_file_path, bucket_name, destination_key)
        
        logger.info(f"Successfully uploaded to s3://{bucket_name}/{destination_key}")
        return destination_key
            
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_msg = e.response['Error']['Message']
        logger.error(f"AWS API error during upload ({error_code}): {error_msg}")
        raise Exception(f"Upload failed: {error_code} - {error_msg}")

def copy_s3_object_across_accounts(source_role_arn, source_bucket, source_prefix,
                                  dest_role_arn, dest_bucket, dest_prefix,
                                  local_dir, cleanup=True):
    """
    Complete workflow: download from source, upload to destination, and remote download
    """
    
    local_file_path = None
    try:
        # Step 1: Download from source bucket to local machine
        local_file_path, filename = download_last_modified_object(
            role_arn=source_role_arn,
            bucket_name=source_bucket,
            prefix=source_prefix,
            local_dir=local_dir
        )
        
        # Step 2: Upload to destination bucket from local machine
        destination_key = upload_to_destination_s3(
            role_arn=dest_role_arn,
            bucket_name=dest_bucket,
            prefix=dest_prefix,
            local_file_path=local_file_path
        )
        
        
        # Step 4: Cleanup if requested
        if cleanup and local_file_path and os.path.exists(local_file_path):
            logger.info(f"Cleaning up local file: {local_file_path}")
            os.remove(local_file_path)
        
        return {
            'success': True,
            'source_file': local_file_path,
            'destination_bucket': dest_bucket,
            'destination_key': destination_key,
            'local_file_cleaned': cleanup,
            'filename': filename
        }
        
    except Exception as e:
        logger.error(f"Cross-account copy failed: {str(e)}")
        
        # Don't cleanup on error for debugging
        if local_file_path and os.path.exists(local_file_path):
            logger.info(f"Local file retained for debugging: {local_file_path}")
        
        return {
            'success': False,
            'error': str(e),
            'source_file': local_file_path,
            'remote_download_success': False
        }

def main():
    """Main function with command line arguments"""
    parser = argparse.ArgumentParser(description='Copy the last modified object between S3 buckets across accounts with remote download using AWS CLI')
    
    # Source arguments
    parser.add_argument('--source-role-arn', required=True, help='Source AWS IAM Role ARN to assume')
    parser.add_argument('--source-bucket', required=True, help='Source S3 bucket name')
    parser.add_argument('--source-prefix', required=True, help='Source S3 prefix/path')
    
    # Destination arguments
    parser.add_argument('--dest-role-arn', required=True, help='Destination AWS IAM Role ARN to assume')
    parser.add_argument('--dest-bucket', required=True, help='Destination S3 bucket name')
    parser.add_argument('--dest-prefix', required=True, help='Destination S3 prefix/path')
    
    # Common arguments
    parser.add_argument('--local-dir', default='C:\\DBBackups\\', help='Local directory for temporary storage')
    parser.add_argument('--region', default='us-east-1', help='AWS region')
    parser.add_argument('--no-cleanup', action='store_true', help='Keep local file after upload')
    
    args = parser.parse_args()
    
    try:
        logger.info("=" * 80)
        logger.info("Starting S3 Cross-Account Copy Process with Remote Download (AWS CLI)")
        logger.info("=" * 80)
        
        # Source info
        logger.info(f"SOURCE:-")
        logger.info(f"  Role ARN: {args.source_role_arn}")
        logger.info(f"  Bucket: {args.source_bucket}")
        logger.info(f"  Prefix: {args.source_prefix}")
        
        # Destination info
        logger.info(f"DESTINATION:-")
        logger.info(f"  Role ARN: {args.dest_role_arn}")
        logger.info(f"  Bucket: {args.dest_bucket}")
        logger.info(f"  Prefix: {args.dest_prefix}")
        
        # Common info
        logger.info(f"LOCAL TEMP DIR: {args.local_dir}")
        logger.info(f"REGION: {args.region}")
        logger.info(f"CLEANUP: {not args.no_cleanup}")
        logger.info("=" * 80)
        
        # Set AWS region if provided
        if args.region:
            os.environ['AWS_DEFAULT_REGION'] = args.region.strip()  # Strip any extra spaces
        
        # Execute the complete process
        result = copy_s3_object_across_accounts(
            source_role_arn=args.source_role_arn,
            source_bucket=args.source_bucket,
            source_prefix=args.source_prefix,
            dest_role_arn=args.dest_role_arn,
            dest_bucket=args.dest_bucket,
            dest_prefix=args.dest_prefix,
            local_dir=args.local_dir,
            cleanup=not args.no_cleanup
        )
        
        logger.info("=" * 80)
        if result['success']:
            logger.info("Complete process finished successfully!")
            logger.info(f"File: {result.get('filename')}")
            logger.info(f"Destination: s3://{result['destination_bucket']}/{result['destination_key']}")
            if result.get('local_file_cleaned'):
                logger.info("Local temporary file cleaned up")
        else:
            logger.error(f"Process failed: {result['error']}")
        logger.info("=" * 80)
        
        return result
        
    except Exception as e:
        logger.error(f"Process failed: {str(e)}", exc_info=True)
        return {'success': False, 'error': str(e)}

if __name__ == "__main__":
    result = main()
    if result and result.get('success'):
        print(f"\nSuccess! Complete process finished successfully!")
        print(f"File: {result.get('filename')}")
        print(f"Destination: s3://{result['destination_bucket']}/{result['destination_key']}")
    else:
        error_msg = result.get('error', 'Unknown error') if result else 'Process failed'
        print(f"\nProcess failed: {error_msg}")
        exit(1)
