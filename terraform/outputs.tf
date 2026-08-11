# Region Output
output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet (for HeadNode)"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet (for ComputeNodes)"
  value       = aws_subnet.private.id
}

# EFS Outputs
output "efs_file_system_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.shared.id
}

output "efs_security_group_id" {
  description = "ID of the EFS security group"
  value       = aws_security_group.efs.id
}

# S3 Outputs
output "s3_bucket_name" {
  description = "Name of the S3 bucket for ParallelCluster"
  value       = aws_s3_bucket.parallelcluster.id
}

output "s3_script_path" {
  description = "S3 path to install_software.sh script"
  value       = "s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}"
}

# Key Pair Outputs
output "key_name" {
  description = "Name of the EC2 key pair"
  value       = aws_key_pair.pcluster.key_name
}

output "private_key_path" {
  description = "Path to the private key file"
  value       = local_file.private_key.filename
}

# ParallelCluster Config Template
output "parallelcluster_config_snippet" {
  description = "Config snippet for ParallelCluster config.yaml"
  value       = <<-EOT
    # Use these values in your config.yaml:

    Region: ${var.aws_region}

    HeadNode:
      Networking:
        SubnetId: ${aws_subnet.public.id}
      Ssh:
        KeyName: ${aws_key_pair.pcluster.key_name}
      CustomActions:
        OnNodeConfigured:
          Script: s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}

    Scheduling:
      SlurmQueues:
        - Name: cpu
          Networking:
            SubnetIds:
              - ${aws_subnet.private.id}
          CustomActions:
            OnNodeConfigured:
              Script: s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}
        - Name: gpu
          Networking:
            SubnetIds:
              - ${aws_subnet.private.id}
          CustomActions:
            OnNodeConfigured:
              Script: s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}

    SharedStorage:
      - MountDir: /shared
        Name: efs-shared
        StorageType: Efs
        EfsSettings:
          FileSystemId: ${aws_efs_file_system.shared.id}
  EOT
}

# ParallelCluster Outputs
output "cluster_name" {
  description = "Name of the ParallelCluster"
  value       = var.cluster_name
}

output "cluster_check_command" {
  description = "Command to check cluster status"
  value       = "pcluster describe-cluster --cluster-name ${var.cluster_name} --region ${var.aws_region}"
}

output "ssh_command" {
  description = "Command to connect to HeadNode"
  value       = "pcluster ssh --cluster-name ${var.cluster_name} --region ${var.aws_region}"
}

output "ssh_key_path" {
  description = "Path to SSH private key (for manual connection)"
  value       = local_file.private_key.filename
}

# Summary Output
output "infrastructure_summary" {
  description = "Summary of created infrastructure"
  value = {
    vpc_id            = aws_vpc.main.id
    public_subnet_id  = aws_subnet.public.id
    private_subnet_id = aws_subnet.private.id
    efs_id            = aws_efs_file_system.shared.id
    s3_bucket         = aws_s3_bucket.parallelcluster.id
    key_name          = aws_key_pair.pcluster.key_name
    region            = var.aws_region
    availability_zone = var.availability_zone
    cluster_name      = var.cluster_name
  }
}
