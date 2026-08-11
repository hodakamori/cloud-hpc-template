# Random ID for unique S3 bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# S3 Bucket for ParallelCluster
resource "aws_s3_bucket" "parallelcluster" {
  bucket = "parallelcluster-${random_id.bucket_suffix.hex}-v1-do-not-delete"

  tags = merge(
    var.tags,
    {
      Name = "parallelcluster-bucket"
    }
  )
}

# Enable versioning
resource "aws_s3_bucket_versioning" "parallelcluster" {
  bucket = aws_s3_bucket.parallelcluster.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "parallelcluster" {
  bucket = aws_s3_bucket.parallelcluster.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload install_software.sh script
resource "aws_s3_object" "install_software" {
  bucket = aws_s3_bucket.parallelcluster.id
  key    = "scripts/install_software.sh"
  source = "${path.module}/../install_software.sh"
  etag   = filemd5("${path.module}/../install_software.sh")

  tags = merge(
    var.tags,
    {
      Name = "install_software_script"
    }
  )
}
