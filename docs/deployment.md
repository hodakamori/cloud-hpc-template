# Deployment

End to end this takes roughly **20–25 minutes**: about 10 minutes for the infrastructure (the RDS
instance dominates) and another 10–12 minutes for the cluster.

## Prerequisites

### Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.0 | Provisions the infrastructure |
| AWS CLI | v1 or v2 | Credentials, and reading the DB password |
| AWS ParallelCluster CLI (`pcluster`) | >= 3.14 | Creates the cluster — **must be on PATH, Terraform invokes it** |
| Python | >= 3.9 | Runtime for `pcluster` |

```bash
# Terraform (macOS)
brew install terraform

# Terraform (Linux)
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# pcluster and awscli, pinned by this repository
uv sync
source .venv/bin/activate

# or with pip
pip install "aws-parallelcluster>=3.14.1" awscli
```

Slurm accounting requires ParallelCluster 3.3.0 or later; this repository pins 3.14.1 or later.

### Credentials and preflight

```bash
aws configure

terraform version
aws sts get-caller-identity
pcluster version          # if this is missing, terraform apply will fail
```

### IAM permissions

The identity running the deployment needs permission to manage at least:

- EC2 — VPC, subnets, IGW, NAT, EIP, route tables, VPC endpoints, security groups, key pairs, instances
- EFS, S3, RDS, Secrets Manager
- CloudFormation — ParallelCluster is deployed as a CloudFormation stack
- IAM — ParallelCluster creates node roles and instance profiles; this template creates a
  customer-managed policy and attaches it to the head node role, which requires `iam:CreatePolicy`,
  `iam:AttachRolePolicy`, and `iam:DetachRolePolicy`
- CloudWatch Logs, Auto Scaling, Lambda, DynamoDB — used internally by ParallelCluster
- `secretsmanager:DescribeSecret` on the accounting secret — ParallelCluster validates the secret at
  cluster creation time, and cluster creation fails without it

`AdministratorAccess` is convenient for evaluation. For anything beyond that, start from the
[official ParallelCluster IAM policies](https://docs.aws.amazon.com/parallelcluster/latest/ug/iam-roles-in-parallelcluster-v3.html).

### Service quotas

The default configuration consumes:

- **2 Elastic IPs** — one for the NAT gateway, one for the head node
- **8 on-demand `g4dn` vCPUs** if both GPU nodes scale up; new accounts often have a quota of 0 here
  and need a limit increase request
- 1 RDS instance and 20 GiB of RDS storage

## Step 1 — Initialize Terraform

```bash
cd terraform
terraform init
```

This downloads the `aws`, `tls`, `local`, `random`, and `null` providers.

## Step 2 — Customize variables (optional)

The defaults work as-is. To change them:

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `ap-northeast-1` | Target region |
| `availability_zone` | `ap-northeast-1a` | AZ for the head node, compute nodes, and EFS — **change this whenever you change the region** |
| `availability_zone_secondary` | `ap-northeast-1c` | Second AZ, required by the RDS DB subnet group |
| `project_name` | `pcluster` | Prefix for resource names |
| `cluster_name` | `my-cluster` | ParallelCluster name, and the name of the per-cluster accounting database |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR |
| `public_subnet_cidr` | `10.0.0.0/24` | Head node subnet |
| `private_subnet_cidr` | `10.0.1.0/24` | Compute node subnet |
| `private_subnet_secondary_cidr` | `10.0.2.0/24` | Secondary subnet, RDS only |
| `key_name` | `pcluster-key-ed25519` | Name of the generated EC2 key pair |
| `db_instance_class` | `db.t4g.micro` | Accounting database instance class |
| `db_engine_version` | `8.0` | MySQL major version |
| `db_parameter_group_family` | `mysql8.0` | Must match `db_engine_version` |
| `db_username` | `slurmadmin` | Database master user |
| `db_port` | `3306` | Database port |
| `db_allocated_storage` | `20` | Initial storage in GiB |
| `db_max_allocated_storage` | `100` | Storage autoscaling ceiling, `0` disables |
| `db_backup_retention_period` | `7` | Automated backup retention in days, `0` disables |
| `db_multi_az` | `false` | Multi-AZ roughly doubles the database cost |
| `db_deletion_protection` | `false` | Must stay `false` for `terraform destroy` to work |
| `db_skip_final_snapshot` | `true` | Set `false` to retain accounting data on destroy |
| `tags` | Project/Environment/ManagedBy | Tags applied to every resource |

## Step 3 — Review and apply

```bash
terraform plan
terraform apply    # type 'yes'
```

`terraform apply` performs the following:

1. Creates the VPC, subnets, NAT, EFS, S3 bucket, and SSH key pair
2. Creates the RDS instance, its parameter group, security groups, and the Secrets Manager secret
3. Uploads `install_software.sh` to S3
4. Renders `config.yaml.tpl` into `terraform/generated-config.yaml`, substituting the real subnet
   IDs, EFS ID, S3 path, database endpoint, secret ARN, and security group ID
5. Runs `pcluster create-cluster` to **start** cluster creation

> **Important:** `pcluster create-cluster` is invoked without `--wait`, so it returns immediately. A
> successful `terraform apply` means cluster creation has started, not that the cluster is ready, and
> an asynchronous cluster failure will not fail the apply. Confirm with Step 4.

## Step 4 — Wait for the cluster

```bash
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1

# or poll
watch -n 30 "pcluster describe-cluster \
  --cluster-name my-cluster \
  --region ap-northeast-1 \
  --query 'clusterStatus' --output text"
```

Wait for `CREATE_IN_PROGRESS` to become **`CREATE_COMPLETE`** (10–12 minutes).

## Step 5 — Connect to the head node

```bash
pcluster ssh --cluster-name my-cluster --region ap-northeast-1
```

This resolves the head node IP, selects the right key, and logs in as `ubuntu`.

To connect manually:

```bash
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1 \
  --query 'headNode.publicIpAddress' --output text

chmod 400 ../pcluster-key-ed25519.pem
ssh -i ../pcluster-key-ed25519.pem ubuntu@<HeadNode-IP>
```

## Verifying the deployment

On the head node:

```bash
sinfo
# PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
# cpu*         up   infinite      2   idle~ cpu-dy-t3medium-[1-2]
# gpu          up   infinite      2   idle~ gpu-dy-g4dnxlarge-[1-2]
#                                        "idle~" means powered down, ready to scale up

df -h /shared          # EFS is mounted
mpirun --version       # OpenMPI
uv --version

# Confirm accounting is live
sacctmgr show cluster

# Boot one compute node (first run takes a few minutes)
srun --partition=cpu --nodes=1 --ntasks=1 hostname
```

## Outputs

```bash
terraform output
terraform output ssh_command
terraform output slurm_database_endpoint
terraform output infrastructure_summary
```

| Output | Description |
|--------|-------------|
| `ssh_command` | Ready-to-run `pcluster ssh` command |
| `cluster_check_command` | Ready-to-run `pcluster describe-cluster` command |
| `ssh_key_path` / `private_key_path` | Location of the generated private key |
| `vpc_id`, `public_subnet_id`, `private_subnet_id` | Networking IDs |
| `efs_file_system_id`, `efs_security_group_id` | EFS IDs |
| `s3_bucket_name`, `s3_script_path` | Bootstrap script location |
| `slurm_database_endpoint` | `host:port`, as used for `SlurmSettings/Database/Uri` |
| `slurm_database_address`, `slurm_database_username` | Database host and master user |
| `slurm_database_secret_arn` | Secrets Manager ARN of the database password |
| `slurm_database_password_command` | Ready-to-run command that prints the database password |
| `db_client_security_group_id`, `rds_security_group_id` | Database security group IDs |
| `parallelcluster_config_snippet` | Config fragment for building a cluster config by hand |
| `infrastructure_summary` | All key IDs in one map |
