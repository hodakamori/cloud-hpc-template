# Generate ED25519 private key
resource "tls_private_key" "ed25519" {
  algorithm = "ED25519"
}

# AWS Key Pair
resource "aws_key_pair" "pcluster" {
  key_name   = var.key_name
  public_key = tls_private_key.ed25519.public_key_openssh

  tags = merge(
    var.tags,
    {
      Name = var.key_name
    }
  )
}

# Save private key to local file
resource "local_file" "private_key" {
  content         = tls_private_key.ed25519.private_key_openssh
  filename        = "${path.module}/../${var.key_name}.pem"
  file_permission = "0400"
}
