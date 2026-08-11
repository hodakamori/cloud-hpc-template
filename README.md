# Cloud HPC Template — AWS ParallelCluster on Terraform

A single `terraform apply` builds a complete HPC cluster on AWS: networking, shared storage,
an AWS ParallelCluster with the Slurm scheduler, and an Amazon RDS database backing
Slurm accounting. LAMMPS build and benchmark scripts are included to verify the cluster works.

- Infrastructure (VPC, subnets, NAT, EFS, S3, SSH key, RDS) provisioned by Terraform
- ParallelCluster created automatically via `pcluster create-cluster`
- Two autoscaling Slurm queues: CPU and GPU, both scaling down to zero nodes
- Slurm accounting enabled, so `sacct` / `sacctmgr` report real job history
- Tear everything down with a single `terraform destroy`

---

## Table of contents

1. [Cluster architecture](#cluster-architecture)
2. [Prerequisites](#prerequisites)
3. [Deployment](#deployment)
4. [Verifying the deployment](#verifying-the-deployment)
5. [Slurm accounting](#slurm-accounting)
6. [Running LAMMPS](#running-lammps)
7. [Operating the cluster](#operating-the-cluster)
8. [Cleanup](#cleanup)
9. [Cost estimate](#cost-estimate)
10. [Customization](#customization)
11. [Troubleshooting](#troubleshooting)
12. [Known caveats](#known-caveats)
13. [Repository layout](#repository-layout)

---

## Cluster architecture

### Overview

```
                                    Internet
                                        │
┌───────────────────────────────────────┼──────────────────────────────────────┐
│ VPC 10.0.0.0/16 (DNS hostnames enabled)                                       │
│                                 Internet Gateway                              │
│                                        │                                      │
│  ┌─────────────────────────────────────┼──────┐  ┌─────────────────────────┐  │
│  │ Public subnet 10.0.0.0/24           │      │  │ Private subnet          │  │
│  │ AZ: ap-northeast-1a                 │      │  │ 10.0.1.0/24             │  │
│  │                                     │      │  │ AZ: ap-northeast-1a     │  │
│  │  ┌──────────────────┐        ┌──────┴────┐ │  │                         │  │
│  │  │ HeadNode         │        │ NAT       │ │  │ ┌─────────────────────┐ │  │
│  │  │ t3.medium        │        │ Gateway   │◄┼──┼─┤ cpu queue           │ │  │
│  │  │ Ubuntu 22.04     │        │ (+EIP)    │ │  │ │ t3.medium   × 0..2  │ │  │
│  │  │ Elastic IP       │        └───────────┘ │  │ └─────────────────────┘ │  │
│  │  │ always on        │                      │  │                         │  │
│  │  │ slurmctld        │                      │  │ ┌─────────────────────┐ │  │
│  │  │ slurmdbd ────────┼──── MySQL 3306 ──┐   │  │ │ gpu queue           │ │  │
│  │  └────────┬─────────┘                  │   │  │ │ g4dn.xlarge × 0..2  │ │  │
│  │           │                            │   │  │ │ NVIDIA T4           │ │  │
│  └───────────┼────────────────────────────┼───┘  │ └──────────┬──────────┘ │  │
│              │                            │      └────────────┼────────────┘  │
│              │                            │                   │               │
│              └──────────────┬─────────────┼───────────────────┘               │
│                             │             │                                   │
│              ┌──────────────┴───────┐     │      ┌──────────────────────────┐ │
│              │ EFS  /shared         │     │      │ S3 Gateway VPC Endpoint  │ │
│              │ encrypted, all nodes │     │      │ (avoids NAT data charges)│ │
│              └──────────────────────┘     │      └──────────────────────────┘ │
│                                           │                                   │
│  ┌────────────────────────────────────────┼─────────────────────────────────┐ │
│  │ DB subnet group (spans two AZs)        │                                 │ │
│  │  ┌─────────────────────────────────────┴──┐  ┌───────────────────────┐   │ │
│  │  │ Private subnet 10.0.1.0/24             │  │ Private subnet        │   │ │
│  │  │ ap-northeast-1a                        │  │ 10.0.2.0/24           │   │ │
│  │  │   RDS MySQL 8.0 (Slurm accounting)     │  │ ap-northeast-1c       │   │ │
│  │  │   encrypted, not publicly accessible   │  │ (AZ coverage only)    │   │ │
│  │  └────────────────────────────────────────┘  └───────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────────────┘
```

- The **head node sits in the public subnet** and is reached over SSH via its Elastic IP.
- **Compute nodes sit in the private subnet** and reach the internet through the NAT gateway.
- **EFS has a single mount target in the primary private subnet.** Mount targets operate per
  Availability Zone, and the security group allows NFS from the whole VPC CIDR, so the head node
  in the public subnet mounts the same `/shared`. **Both subnets must therefore stay in the same AZ.**
- The **S3 gateway VPC endpoint** is attached to both route tables, so the node bootstrap script is
  fetched from S3 without incurring NAT data processing charges.
- **RDS is only reachable from the head node.** A dedicated client security group is attached to the
  head node, and the database security group allows port 3306 from that group only — nothing else in
  the VPC can connect.
- The **second private subnet in a different AZ exists solely to satisfy RDS**, which requires a DB
  subnet group covering at least two Availability Zones even for a Single-AZ instance. No compute
  resources are placed there.

### AWS resources created

| Category | Resource | Configuration |
|----------|----------|---------------|
| Network | VPC | `10.0.0.0/16`, DNS hostnames and DNS support enabled (required by ParallelCluster) |
| | Public subnet | `10.0.0.0/24` (head node) |
| | Private subnet | `10.0.1.0/24` (compute nodes, EFS mount target, RDS) |
| | Private subnet (secondary) | `10.0.2.0/24` in a second AZ, for the RDS DB subnet group only |
| | Internet Gateway | Outbound access for the public subnet |
| | NAT Gateway + EIP | Outbound access for the private subnets |
| | Route tables ×2 | public → IGW, private → NAT |
| | S3 Gateway VPC Endpoint | Attached to both route tables |
| Storage | EFS | Encrypted, `generalPurpose` / `bursting`, transitions to IA after 30 days, mounted at `/shared` on every node |
| | EFS security group | Allows TCP 2049 (NFS) from the VPC CIDR |
| | S3 bucket | `parallelcluster-<random>-v1-do-not-delete`, versioned, all public access blocked |
| | S3 object | `scripts/install_software.sh` (node bootstrap script) |
| Database | RDS for MySQL 8.0 | `db.t4g.micro`, gp3 storage with autoscaling, encrypted at rest, Single-AZ, not publicly accessible, 7-day backups |
| | DB subnet group | Spans the two private subnets |
| | DB parameter group | `require_secure_transport=ON`, `innodb_lock_wait_timeout=900` |
| | RDS security group | Allows TCP 3306 from the DB client security group only |
| | DB client security group | Attached to the head node to grant database access |
| | Secrets Manager secret | Holds the database master password as plain text |
| | IAM policy | Grants the head node `secretsmanager:GetSecretValue` on that secret |
| Auth | SSH key pair | ED25519 generated by Terraform; private key written to the repository root as `pcluster-key-ed25519.pem` (mode 0400) |
| Cluster | ParallelCluster | Created from the rendered `terraform/generated-config.yaml` |

### Node configuration

| Role | Instance | Count | Placement | Notes |
|------|----------|-------|-----------|-------|
| HeadNode | `t3.medium` (2 vCPU / 4 GiB) | 1, always on | Public subnet | Elastic IP, runs `slurmctld` and `slurmdbd`, used for job submission |
| `cpu` queue | `t3.medium` (2 vCPU / 4 GiB) | 0–2, autoscaling | Private subnet | Compute resource name `t3medium` |
| `gpu` queue | `g4dn.xlarge` (4 vCPU / 16 GiB / NVIDIA T4 16 GB) | 0–2, autoscaling | Private subnet | Compute resource name `g4dnxlarge` |

- The scheduler is **Slurm**. Queue names map directly to Slurm partitions
  (`--partition=cpu`, `--partition=gpu`).
- Compute nodes use `MinCount: 0`, so they **scale to zero when idle** and cost nothing.
  Expect a few minutes between job submission and job start while a node boots and bootstraps.
- All nodes get `AmazonS3ReadOnlyAccess` so they can fetch the bootstrap script; the head node
  additionally gets a scoped policy to read the database password from Secrets Manager.

### Software stack

`install_software.sh` runs on every node as the `OnNodeConfigured` custom action and installs:

| Component | Detail |
|-----------|--------|
| OS | Ubuntu 22.04 (`ubuntu2204`) |
| Scheduler | Slurm (provided by ParallelCluster) |
| Compiler | GCC 11.x (`build-essential`) |
| MPI | OpenMPI 4.1.x (`libopenmpi-dev`, `openmpi-bin`) |
| Build tools | CMake 3.22.x |
| Math library | FFTW3 (`libfftw3-dev`) |
| Database client | `mysql-client`, for inspecting the accounting database by hand |
| GPU | CUDA Toolkit 12.3, **GPU nodes only** — detected automatically via `lspci` |
| Python | python3 plus `uv` at `/usr/local/bin/uv` |
| Application | LAMMPS with Kokkos (OpenMP on CPU, CUDA on GPU) — built manually, see below |

> LAMMPS itself is not part of the bootstrap. Build it after the cluster is up using the
> scripts in `utils/`.

---

## Prerequisites

### Required tools

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

### AWS credentials

```bash
aws configure
```

### Preflight check

```bash
terraform version
aws sts get-caller-identity
pcluster version          # if this is missing, terraform apply will fail
```

### IAM permissions

The identity running the deployment needs permission to manage at least:

- EC2 — VPC, subnets, IGW, NAT, EIP, route tables, VPC endpoints, security groups, key pairs, instances
- EFS, S3, RDS, Secrets Manager
- CloudFormation — ParallelCluster is deployed as a CloudFormation stack
- IAM — ParallelCluster creates node roles and instance profiles; this template creates a customer-managed policy and attaches it to the head node role, which requires `iam:CreatePolicy`, `iam:AttachRolePolicy`, and `iam:DetachRolePolicy`
- CloudWatch Logs, Auto Scaling, Lambda, DynamoDB — used internally by ParallelCluster
- `secretsmanager:DescribeSecret` on the accounting secret — ParallelCluster validates the secret at cluster creation time

`AdministratorAccess` is convenient for evaluation. For anything beyond that, start from the
[official ParallelCluster IAM policies](https://docs.aws.amazon.com/parallelcluster/latest/ug/iam-roles-in-parallelcluster-v3.html).

### Service quotas

The default configuration consumes:

- **2 Elastic IPs** — one for the NAT gateway, one for the head node
- **8 on-demand `g4dn` vCPUs** if both GPU nodes scale up; new accounts often have a quota of 0 here
  and need a limit increase request
- 1 RDS instance and 20 GiB of RDS storage

---

## Deployment

End to end this takes roughly **20–25 minutes**: about 10 minutes for the infrastructure
(the RDS instance dominates) and another 10–12 minutes for the cluster.

### Step 1 — Initialize Terraform

```bash
cd terraform
terraform init
```

This downloads the `aws`, `tls`, `local`, `random`, and `null` providers.

### Step 2 — Customize variables (optional)

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
| `db_allocated_storage` | `20` | Initial storage in GiB |
| `db_max_allocated_storage` | `100` | Storage autoscaling ceiling |
| `db_backup_retention_period` | `7` | Automated backup retention in days, `0` disables |
| `db_multi_az` | `false` | Multi-AZ roughly doubles the database cost |
| `db_deletion_protection` | `false` | Must stay `false` for `terraform destroy` to work |
| `db_skip_final_snapshot` | `true` | Set `false` to retain accounting data on destroy |
| `tags` | Project/Environment/ManagedBy | Tags applied to every resource |

### Step 3 — Review and apply

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

> **Important:** `pcluster create-cluster` returns immediately without waiting. A successful
> `terraform apply` means cluster creation has started, not that the cluster is ready. Confirm with
> Step 4.

### Step 4 — Wait for the cluster

```bash
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1

# or poll
watch -n 30 "pcluster describe-cluster \
  --cluster-name my-cluster \
  --region ap-northeast-1 \
  --query 'clusterStatus' --output text"
```

Wait for `CREATE_IN_PROGRESS` to become **`CREATE_COMPLETE`** (10–12 minutes).

### Step 5 — Connect to the head node

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

### Reading the outputs

```bash
terraform output
terraform output ssh_command
terraform output slurm_database_endpoint
terraform output infrastructure_summary
```

---

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

---

## Slurm accounting

Accounting is enabled through `Scheduling/SlurmSettings/Database` in the cluster config. The head
node runs `slurmdbd`, which connects to the RDS instance over TLS and records every job.
`slurmdbd` creates and owns its own database on that server, named after the cluster
(`my-cluster` by default), so multiple clusters can share one RDS instance without colliding.

### What it enables

```bash
# Job history, including finished jobs
sacct
sacct --starttime 2026-01-01 --format=JobID,JobName,Partition,AllocCPUS,Elapsed,State,ExitCode

# Per-user resource usage
sreport cluster AccountUtilizationByUser start=2026-01-01

# Fair-share and account management
sacctmgr show cluster
sacctmgr add account research Description="Research group"
sacctmgr add user alice Account=research
sacctmgr show associations

# Enforce limits with QOS
sacctmgr add qos short MaxWall=01:00:00
```

Without accounting, `sacct` only reports jobs still known to `slurmctld`; with it, history survives
head node restarts.

> ParallelCluster performs a minimal bootstrap: it registers the cluster and sets the default cluster
> user as database admin. Creating accounts, users, associations, and QOS entries is up to you.

### Connecting to the database by hand

The database is not publicly accessible, so connect from the head node. `mysql-client` is installed
by the bootstrap script.

```bash
# Fetch the password (run where AWS credentials are configured, e.g. your workstation)
terraform output -raw slurm_database_password_command | bash

# From the head node. TLS is mandatory: the parameter group sets require_secure_transport=ON
mysql -h <rds-endpoint> -P 3306 -u slurmadmin -p --ssl-mode=REQUIRED

mysql> SHOW DATABASES;
mysql> USE <database-name>;
mysql> SHOW TABLES;
```

The exact database name is whatever `slurmdbd` was configured to use. Read it off the head node
rather than guessing:

```bash
sudo grep StorageLoc /opt/slurm/etc/slurmdbd.conf
```

### Rotating the password

Changing the secret value does **not** propagate to the cluster automatically. Stop the compute
fleet first to avoid losing accounting data, then run the ParallelCluster helper on the head node:

```bash
pcluster update-compute-fleet --cluster-name my-cluster --region ap-northeast-1 \
  --status STOP_REQUESTED

# on the head node
sudo /opt/parallelcluster/scripts/slurm/update_slurm_database_password.sh

pcluster update-compute-fleet --cluster-name my-cluster --region ap-northeast-1 \
  --status START_REQUESTED
```

Changing `UserName` or `PasswordSecretArn` in the cluster config also requires the compute fleet to
be stopped, or `QueueUpdateStrategy` to be set.

---

## Running LAMMPS

The scripts in `utils/` run on the head node. Copy them over or clone this repository there.

```bash
scp -i pcluster-key-ed25519.pem -r utils ubuntu@<HeadNode-IP>:~/
```

### Preparing `/shared`

`/shared` (EFS) is owned by root initially, so grant write access before building.

```bash
sudo chown ubuntu:ubuntu /shared
sudo mkdir -p /shared/lammps_jobs
sudo chown ubuntu:ubuntu /shared/lammps_jobs

# The MPI test job reads its input from the home directory
cp ~/utils/lammps_test_input.lmp ~/lammps_test_input.lmp
```

### Building the CPU version

```bash
./utils/build_lammps_cpu.sh
```

- Clones LAMMPS to `/shared/lammps`, builds in `build-cpu`, installs to `/shared/lammps/cpu`
- Enabled packages: `KOKKOS` (OpenMP), `MOLECULE`, `KSPACE`, `RIGID`, `MANYBODY`, MPI, OpenMP
- Log: `/shared/lammps_cpu_build.log`
- **The head node has only 2 vCPUs, so this can take 30 minutes or more.** Run it inside `tmux` or
  `screen`, or submit it as a batch job.

```bash
source /shared/lammps/cpu-env.sh
lmp -h
```

### Building the GPU version

CUDA and a GPU are required, so this is submitted to the GPU queue.

```bash
sbatch utils/build_lammps_gpu.sh

squeue
tail -f /shared/lammps_gpu_build_*.out
```

- Installs to `/shared/lammps/gpu`, environment script at `/shared/lammps/gpu-env.sh`
- The Kokkos GPU architecture is set to `Kokkos_ARCH_TURING75`, matching the NVIDIA T4 in `g4dn`
  instances. Change it if you switch instance types — `p3` (V100) uses `Kokkos_ARCH_VOLTA70`,
  `g5` (A10G) uses `Kokkos_ARCH_AMPERE86`.

### MPI test

```bash
sbatch utils/run_lammps_mpi_test.sh

squeue
watch -n 5 sinfo
cat lammps_test_*.out
```

Runs a Lennard-Jones fluid benchmark (32,000 atoms, 5,000 steps) across 2 nodes and 4 MPI ranks.
Working directory is `/shared/lammps_jobs/<JOB_ID>`. The job reads
`/home/ubuntu/lammps_test_input.lmp`, so do not skip the copy step above.

### Scaling test

```bash
./utils/run_lammps_scaling_test.sh
```

Submits four configurations and collects `Loop time` for each:

| Nodes | MPI ranks |
|-------|-----------|
| 1 | 1 |
| 1 | 2 |
| 2 | 2 |
| 2 | 4 |

```bash
cat /shared/lammps_scaling_results_*/summary.txt

# With accounting enabled, compare runtimes directly
sacct --format=JobID,JobName,NNodes,NTasks,Elapsed,State
```

> The `cpu` queue caps at 2 nodes, so the two-node configurations queue rather than run concurrently.

---

## Operating the cluster

### Slurm commands

| Command | Description |
|---------|-------------|
| `sinfo` | Partition and node status |
| `squeue` | Job queue |
| `sbatch <script>` | Submit a batch job |
| `srun <cmd>` | Run interactively |
| `scancel <job_id>` | Cancel a job |
| `scontrol show job <job_id>` | Job detail |
| `sacct` | Job history (requires accounting) |
| `sacctmgr` | Manage accounts, users, QOS (requires accounting) |
| `sreport` | Usage reports (requires accounting) |

### Logs

```bash
pcluster list-cluster-log-streams --cluster-name my-cluster --region ap-northeast-1
pcluster get-cluster-log-events --cluster-name my-cluster \
  --log-stream-name <stream-name> --region ap-northeast-1
```

On the nodes:

- `/var/log/parallelcluster/install_software.log` — this template's bootstrap script
- `/var/log/parallelcluster/clustermgtd` — autoscaling, head node
- `/var/log/slurmctld.log` — Slurm controller
- `/var/log/slurmdbd.log` — accounting daemon, the first place to look for database issues

### Applying configuration changes

Editing `terraform/config.yaml.tpl` (instance types, node counts, and so on) changes the
`null_resource` trigger, so `terraform apply` **deletes and recreates the cluster**. Data in
`/shared` (EFS) and the accounting database survive, because both are separate Terraform resources.

For queue or node count changes alone, stopping the compute fleet and running
`pcluster update-cluster` is much faster.

---

## Cleanup

```bash
cd terraform
terraform destroy    # type 'yes'
```

What happens:

1. `pcluster delete-cluster` runs
2. Terraform polls for deletion every 10 seconds, up to 60 times (10 minutes)
3. The infrastructure is deleted: VPC, NAT, EFS, S3, RDS, Secrets Manager secret, key pair

Total time is roughly **20–25 minutes**.

> ⚠️ **All data in `/shared` (EFS) is destroyed.** Copy out anything you need first.
>
> ⚠️ **The accounting database is destroyed too.** `db_skip_final_snapshot` defaults to `true`, so
> no snapshot is kept. Set it to `false` if you want the job history retained.
>
> ⚠️ The NAT gateway, head node, and RDS instance bill continuously while they exist. Destroy the
> stack when you are not using it.

To delete only the cluster and keep the infrastructure:

```bash
pcluster delete-cluster --cluster-name my-cluster --region ap-northeast-1
```

If the S3 bucket blocks deletion, empty it first — versioning is enabled:

```bash
aws s3 rm s3://<bucket-name> --recursive
aws s3api delete-bucket --bucket <bucket-name> --region ap-northeast-1
```

---

## Cost estimate

Rough figures for ap-northeast-1. **Verify against the [AWS pricing pages](https://aws.amazon.com/pricing/)
before relying on them** — these are approximate and change over time.

**Always on, while the stack exists**

| Item | Approximate rate | Approximate monthly |
|------|------------------|---------------------|
| NAT Gateway | ~$0.045/hr plus data processing | ~$33 |
| HeadNode (`t3.medium`) | ~$0.0416/hr | ~$30 |
| RDS (`db.t4g.micro`, Single-AZ) | ~$0.02/hr | ~$15 |
| RDS storage (20 GiB gp3) + backups | ~$0.14/GiB-month | ~$3 |
| Elastic IPs ×2 | low while attached | a few dollars |
| **Subtotal** | | **~$85/month** |

**Only while jobs run**

| Item | Approximate rate |
|------|------------------|
| CPU node (`t3.medium`) | ~$0.0416/hr per node |
| GPU node (`g4dn.xlarge`) | ~$0.526/hr per node |

**Storage**

| Item | Approximate rate |
|------|------------------|
| EFS standard | ~$0.30/GB-month, dropping after the 30-day IA transition |
| S3 | ~$0.025/GB-month, negligible for scripts |

**Keeping costs down**

- Compute nodes use `MinCount: 0`, so an idle cluster costs nothing in compute
- Destroying the stack when idle is by far the biggest saving — it removes the NAT gateway and RDS
- Setting `db_backup_retention_period = 0` and shrinking `db_allocated_storage` trims the database cost
- The S3 gateway VPC endpoint already avoids NAT data processing charges for S3 traffic

---

## Customization

### Changing region

Always update both AZ variables alongside the region.

```hcl
# terraform/terraform.tfvars
aws_region                  = "us-east-1"
availability_zone           = "us-east-1a"
availability_zone_secondary = "us-east-1b"
```

### Changing instance types and node counts

Edit `terraform/config.yaml.tpl`:

```yaml
    - Name: cpu
      ComputeResources:
        - Name: c6i8xlarge          # alphanumeric only
          InstanceType: c6i.8xlarge
          MinCount: 0
          MaxCount: 8
```

- Check your regional vCPU quota before raising `MaxCount`
- For MPI-heavy multi-node work, consider `Efa: Enabled: true` on EFA-capable instances
- If you change the GPU instance type, update `Kokkos_ARCH_*` in `utils/build_lammps_gpu.sh`

### Sizing the accounting database

`db.t4g.micro` is sized for evaluation. ParallelCluster recommends a larger head node when
accounting is enabled, since `slurmdbd` adds load there as well.

```hcl
db_instance_class          = "db.t4g.small"
db_multi_az                = true
db_backup_retention_period = 30
db_skip_final_snapshot     = false
```

If `db.t4g.micro` is unavailable in your region, `db.t3.micro` is the most widely available fallback.

### Sharing one database across clusters

`slurmdbd` names its database after the cluster, so a second cluster pointed at the same RDS endpoint
gets its own separate database. Reuse `slurm_database_endpoint`, `slurm_database_username`, and
`slurm_database_secret_arn` in the other cluster's config, and attach `db_client_security_group_id`
to its head node. Note that AWS advises against having two clusters share a single database at once.

### Adding software to the bootstrap

Edit `install_software.sh` and run `terraform apply`. The S3 object's `etag` changes, which
recreates the cluster and applies the new script.

### Manual deployment

The `config.yaml` at the repository root is a reference for running `pcluster create-cluster` by hand
against pre-existing infrastructure. Replace every `<...>` placeholder with real values; Terraform
does not use this file.

---

## Troubleshooting

### `terraform apply` fails with `pcluster: command not found`

The `pcluster` CLI must be on the PATH of the machine running Terraform.

```bash
uv sync && source .venv/bin/activate
pcluster version
```

### Cluster reaches `CREATE_FAILED`

```bash
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1
pcluster list-cluster-log-streams --cluster-name my-cluster --region ap-northeast-1
pcluster get-cluster-log-events --cluster-name my-cluster \
  --log-stream-name <stream> --region ap-northeast-1
```

Common causes:

- Missing IAM permissions, especially CloudFormation and IAM role creation
- Insufficient vCPU quota, or the instance type is unavailable in the chosen AZ
- Elastic IP quota exhausted
- `secretsmanager:DescribeSecret` missing from the deploying identity — cluster validation fails
- The bootstrap script failed; check `/var/log/parallelcluster/install_software.log`

A failed cluster is not removed automatically. Delete it before retrying:

```bash
pcluster delete-cluster --cluster-name my-cluster --region ap-northeast-1
```

### `sacct` reports that accounting is not enabled

```bash
# On the head node
sudo systemctl status slurmdbd
sudo tail -50 /var/log/slurmdbd.log
sacctmgr show cluster
```

Things to check, in order:

1. **Connectivity** — `timeout 5 bash -c '</dev/tcp/<rds-endpoint>/3306' && echo reachable`.
   If it times out, the head node is missing the DB client security group, or the RDS ingress rule
   is absent.
2. **Credentials** — confirm the head node can read the secret:
   `aws secretsmanager get-secret-value --secret-id <arn> --region <region>`.
   A denial means the IAM policy is not attached to the head node role.
3. **TLS** — `require_secure_transport=ON` rejects unencrypted connections. `slurmdbd` negotiates
   TLS by default, but a manual `mysql` client without `--ssl-mode=REQUIRED` will be refused.
4. **Database reachability** — the RDS instance must be `available` in the console.

### Compute nodes never start, or immediately fail

```bash
sinfo -R
sudo tail -f /var/log/parallelcluster/clustermgtd
```

Usually insufficient capacity for the instance type, or a quota limit.

### Cannot write to `/shared`

```bash
sudo chown ubuntu:ubuntu /shared
sudo chown -R ubuntu:ubuntu /shared/lammps /shared/lammps_jobs
```

### LAMMPS build failures

```bash
cat /shared/lammps_cpu_build.log
cat /shared/lammps_gpu_build.log

gcc --version     # 11.x
cmake --version   # 3.22.x
mpirun --version  # 4.1.x
nvcc --version    # 12.3 on GPU nodes
nvidia-smi
```

The head node has 4 GiB of RAM, so a parallel compile can be killed by the OOM killer. Fall back to
`make -j1` or build on a larger instance.

### `terraform destroy` fails on the VPC

The cluster deletion poll times out after 10 minutes and Terraform proceeds anyway, which can leave
the VPC with dependent resources still attached. Wait for the cluster to finish deleting, then run
`terraform destroy` again.

### Terraform state drift

```bash
terraform refresh
terraform show
terraform state list
```

If you deleted the cluster manually, Terraform still believes it exists:

```bash
terraform state rm null_resource.pcluster_create
```

---

## Known caveats

- **`terraform apply` does not wait for the cluster.** `pcluster create-cluster` is invoked without
  `--wait`, so a successful apply does not mean the cluster is usable. Poll `describe-cluster`.
- **The SSH private key is written to the repository root in plain text**
  (`pcluster-key-ed25519.pem`). The root `.gitignore` excludes `*.pem`, but be careful not to commit
  it. The key is also stored in plain text in the Terraform state, as is the database password — treat
  `terraform.tfstate` as a secret and use an encrypted remote backend for anything shared.
- **SSH on the head node is open to the world** by default, which is ParallelCluster's default
  behaviour. Restrict it with `HeadNode/Ssh/AllowedIps` in real deployments.
- **The public and primary private subnets must share an AZ**, because EFS has a single mount target
  in the primary private subnet.
- **The Secrets Manager secret is created with `recovery_window_in_days = 0`.** Destroying the stack
  deletes the secret immediately with no recovery window. This is deliberate: the default 30-day
  window keeps the name reserved and makes an immediate re-apply fail.
- **Accounting adds load to the head node.** AWS recommends a larger head node instance type when
  `slurmdbd` runs there; `t3.medium` is kept here to hold the evaluation cost down.
- **Traffic between the cluster and the database is encrypted, but identity verification is not
  enabled.** For production, upload the RDS CA certificate to the head node and set `SSL_CA` in
  `slurmdbd.conf` `StorageParameters`.
- This template targets evaluation and learning. For production, add least-privilege IAM, a remote
  Terraform backend with state encryption, EFS backups, RDS Multi-AZ, and CloudWatch alarms.

---

## Repository layout

```
cloud-hpc-template/
├── README.md                      # This document
├── config.yaml                    # Reference pcluster config for manual deployment (unused by Terraform)
├── install_software.sh            # Node bootstrap, run via OnNodeConfigured on every node
├── pyproject.toml / uv.lock       # pcluster and awscli dependency pinning
├── .gitignore
│
├── terraform/                     # Infrastructure as Code
│   ├── main.tf                    # Providers: aws, tls, local, random, null
│   ├── variables.tf               # Input variables
│   ├── vpc.tf                     # VPC, subnets, IGW, NAT, routes, S3 endpoint
│   ├── efs.tf                     # EFS, security group, mount target
│   ├── s3.tf                      # S3 bucket and bootstrap script upload
│   ├── rds.tf                     # Slurm accounting database, secret, security groups, IAM policy
│   ├── key_pair.tf                # ED25519 key generation and storage
│   ├── pcluster.tf                # Config rendering and pcluster create/delete
│   ├── outputs.tf                 # Outputs
│   ├── config.yaml.tpl            # ParallelCluster config template
│   ├── terraform.tfvars.example   # Example variable values
│   └── .gitignore
│
└── utils/                         # Scripts to run on the head node
    ├── build_lammps_cpu.sh        # LAMMPS CPU build (Kokkos OpenMP)
    ├── build_lammps_gpu.sh        # LAMMPS GPU build (Kokkos CUDA, Slurm job)
    ├── lammps_test_input.lmp      # Lennard-Jones benchmark input
    ├── run_lammps_mpi_test.sh     # 2-node, 4-rank MPI test job
    └── run_lammps_scaling_test.sh # Scaling test suite
```

---

## References

- [AWS ParallelCluster documentation](https://docs.aws.amazon.com/parallelcluster/)
- [Slurm accounting with AWS ParallelCluster](https://docs.aws.amazon.com/parallelcluster/latest/ug/slurm-accounting-v3.html)
- [Cluster configuration file reference](https://docs.aws.amazon.com/parallelcluster/latest/ug/cluster-configuration-file-v3.html)
- [Terraform AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Slurm accounting](https://slurm.schedmd.com/accounting.html)
- [LAMMPS documentation](https://docs.lammps.org/)
- [Kokkos build keywords](https://kokkos.org/kokkos-core-wiki/keywords.html)

---

## License

Provided as-is for educational and research use.

Ported from the `055_parallel_cluster` example in
[hodakamori/ml-tutorial](https://github.com/hodakamori/ml-tutorial).
