variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "pcluster"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet (HeadNode)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for private subnet (ComputeNodes)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for subnets"
  type        = string
  default     = "ap-northeast-1a"
}

variable "key_name" {
  description = "Name for EC2 key pair"
  type        = string
  default     = "pcluster-key-ed25519"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "ParallelCluster"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

variable "cluster_name" {
  description = "Name for the ParallelCluster"
  type        = string
  default     = "my-cluster"
}

# --- Slurm accounting database (Amazon RDS) ---

variable "availability_zone_secondary" {
  description = "Second availability zone, required because an RDS DB subnet group must span two AZs. Must differ from availability_zone and be in the same region."
  type        = string
  default     = "ap-northeast-1c"
}

variable "private_subnet_secondary_cidr" {
  description = "CIDR block for the second private subnet (RDS DB subnet group only)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "db_instance_class" {
  description = "Instance class for the Slurm accounting database. Increase for production workloads."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "MySQL major version for the Slurm accounting database"
  type        = string
  default     = "8.0"
}

variable "db_parameter_group_family" {
  description = "RDS parameter group family. Must match db_engine_version (e.g. mysql8.0 for 8.0)."
  type        = string
  default     = "mysql8.0"
}

variable "db_username" {
  description = "Master user name for the Slurm accounting database. Cannot be a MySQL reserved name such as 'admin'."
  type        = string
  default     = "slurmadmin"
}

variable "db_port" {
  description = "Port the Slurm accounting database listens on"
  type        = number
  default     = 3306
}

variable "db_allocated_storage" {
  description = "Initial storage for the Slurm accounting database, in GiB (gp3 requires at least 20)"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling, in GiB. Set to 0 to disable autoscaling."
  type        = number
  default     = 100
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated database backups. Set to 0 to disable backups."
  type        = number
  default     = 7
}

variable "db_multi_az" {
  description = "Whether to run the Slurm accounting database as Multi-AZ. Roughly doubles the database cost."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Whether to enable RDS deletion protection. Leave false so that terraform destroy can remove the database."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Whether to skip the final snapshot on database deletion. Set to false to keep accounting data after terraform destroy."
  type        = bool
  default     = true
}

# --- Optional custom AMI built from install_software.sh (pcluster build-image) ---

variable "build_custom_ami" {
  description = "When true, build a custom AMI from install_software.sh and use it as the compute queues' CustomAmi. Adds 30-90 minutes to terraform apply."
  type        = bool
  default     = false
}

variable "image_os" {
  description = "OS for the custom image. Must match the Image/Os in the cluster config (ubuntu2204)."
  type        = string
  default     = "ubuntu2204"
}

variable "image_id_prefix" {
  description = "Prefix for the pcluster image id. A short hash of install_software.sh is appended so a changed script triggers a rebuild."
  type        = string
  default     = "hpc-baked"
}

variable "parent_image_ami" {
  description = "Base AMI for the build (ParentImage). Leave empty to auto-resolve the official ParallelCluster AMI for image_os via `pcluster list-official-images`."
  type        = string
  default     = ""
}

variable "image_builder_instance_type" {
  description = "EC2 instance type used to build the custom AMI. Use a GPU instance (e.g. g4dn.xlarge) if you want CUDA baked into the image."
  type        = string
  default     = "c5.xlarge"
}
