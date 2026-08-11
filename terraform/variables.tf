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
