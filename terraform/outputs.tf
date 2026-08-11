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

# Slurm Accounting Database Outputs
output "slurm_database_endpoint" {
  description = "Endpoint of the Slurm accounting database (host:port), as used for SlurmSettings/Database/Uri"
  value       = "${aws_db_instance.slurm_accounting.address}:${aws_db_instance.slurm_accounting.port}"
}

output "slurm_database_address" {
  description = "Hostname of the Slurm accounting database"
  value       = aws_db_instance.slurm_accounting.address
}

output "slurm_database_username" {
  description = "Master user name of the Slurm accounting database"
  value       = aws_db_instance.slurm_accounting.username
}

output "slurm_database_secret_arn" {
  description = "Secrets Manager ARN holding the Slurm accounting database password"
  value       = aws_secretsmanager_secret.slurm_accounting.arn
}

output "slurm_database_password_command" {
  description = "Command to read the Slurm accounting database password"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.slurm_accounting.arn} --region ${var.aws_region} --query SecretString --output text"
}

output "slurm_database_note" {
  description = "How the per-cluster accounting database is named"
  value       = "slurmdbd creates its own database on this server, named after the cluster (${var.cluster_name}) via slurmdbd.conf StorageLoc."
}

output "db_client_security_group_id" {
  description = "Security group attached to the head node that grants database access"
  value       = aws_security_group.db_client.id
}

output "rds_security_group_id" {
  description = "Security group attached to the Slurm accounting database"
  value       = aws_security_group.rds.id
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
        AdditionalSecurityGroups:
          - ${aws_security_group.db_client.id}
      Ssh:
        KeyName: ${aws_key_pair.pcluster.key_name}
      Iam:
        AdditionalIamPolicies:
          - Policy: ${aws_iam_policy.slurm_db_secret_read.arn}
      CustomActions:
        OnNodeConfigured:
          Script: s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}

    Scheduling:
      SlurmSettings:
        Database:
          Uri: ${aws_db_instance.slurm_accounting.address}:${aws_db_instance.slurm_accounting.port}
          UserName: ${aws_db_instance.slurm_accounting.username}
          PasswordSecretArn: ${aws_secretsmanager_secret.slurm_accounting.arn}
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

# Custom AMI Outputs (only meaningful when build_custom_ami = true)
output "custom_ami_enabled" {
  description = "Whether a custom AMI was built and applied to the compute queues"
  value       = var.build_custom_ami
}

output "custom_ami_image_id" {
  description = "pcluster image id used for the build (empty when disabled)"
  value       = var.build_custom_ami ? local.image_id : ""
}

output "custom_ami_id" {
  description = "AMI id baked from install_software.sh and used as the queues' CustomAmi (empty when disabled)"
  value       = local.custom_ami
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
    vpc_id                      = aws_vpc.main.id
    public_subnet_id            = aws_subnet.public.id
    private_subnet_id           = aws_subnet.private.id
    private_subnet_secondary_id = aws_subnet.private_secondary.id
    efs_id                      = aws_efs_file_system.shared.id
    s3_bucket                   = aws_s3_bucket.parallelcluster.id
    key_name                    = aws_key_pair.pcluster.key_name
    region                      = var.aws_region
    availability_zone           = var.availability_zone
    availability_zone_secondary = var.availability_zone_secondary
    cluster_name                = var.cluster_name
    slurm_database_endpoint     = "${aws_db_instance.slurm_accounting.address}:${aws_db_instance.slurm_accounting.port}"
    slurm_database_secret_arn   = aws_secretsmanager_secret.slurm_accounting.arn
  }
}
