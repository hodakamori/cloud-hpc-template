# Architecture

## Overview

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

## Design notes

**Head node placement.** The head node sits in the public subnet and is reached over SSH via its
Elastic IP. Compute nodes sit in the private subnet and reach the internet through the NAT gateway.

**EFS and the AZ constraint.** EFS has a single mount target, in the primary private subnet. Mount
targets operate per Availability Zone, and the security group allows NFS from the whole VPC CIDR, so
the head node in the public subnet mounts the same `/shared`. **Both subnets must therefore stay in
the same AZ.** Changing `availability_zone` without changing the region, or vice versa, breaks this.

**S3 gateway endpoint.** Attached to both route tables, so the node bootstrap script is fetched from
S3 without incurring NAT data processing charges.

**Database isolation.** RDS is reachable from the head node only. A dedicated client security group
is attached to the head node, and the database security group admits port 3306 from that group
alone — nothing else in the VPC can connect. Only the head node runs `slurmdbd`, so compute nodes
never need database access.

**The second private subnet.** It exists solely to satisfy RDS, which requires a DB subnet group
covering at least two Availability Zones even for a Single-AZ instance. No compute resources are
placed there, and the database instance itself is pinned to the primary AZ so that `slurmdbd`
queries do not cross an AZ boundary. That pinning is skipped when `db_multi_az` is enabled, because
Multi-AZ manages placement itself and rejects an explicit AZ.

## AWS resources

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
| Database | RDS for MySQL 8.0 | `db.t4g.micro`, gp3 with storage autoscaling, encrypted at rest, Single-AZ, not publicly accessible, 7-day backups |
| | DB subnet group | Spans the two private subnets |
| | DB parameter group | `require_secure_transport=ON`, `innodb_lock_wait_timeout=900` |
| | RDS security group | Allows TCP 3306 from the DB client security group only |
| | DB client security group | Attached to the head node to grant database access |
| | Secrets Manager secret | Holds the database master password as plain text |
| | IAM policy | Grants the head node `secretsmanager:GetSecretValue` on that secret |
| Auth | SSH key pair | ED25519 generated by Terraform; private key written to the repository root as `pcluster-key-ed25519.pem` (mode 0400) |
| Cluster | ParallelCluster | Created from the rendered `terraform/generated-config.yaml` |

## Nodes

| Role | Instance | Count | Placement | Notes |
|------|----------|-------|-----------|-------|
| HeadNode | `t3.medium` (2 vCPU / 4 GiB) | 1, always on | Public subnet | Elastic IP, runs `slurmctld` and `slurmdbd`, used for job submission |
| `cpu` queue | `t3.medium` (2 vCPU / 4 GiB) | 0–2, autoscaling | Private subnet | Compute resource name `t3medium` |
| `gpu` queue | `g4dn.xlarge` (4 vCPU / 16 GiB / NVIDIA T4 16 GB) | 0–2, autoscaling | Private subnet | Compute resource name `g4dnxlarge` |

Queue names map directly to Slurm partitions (`--partition=cpu`, `--partition=gpu`). Compute nodes
use `MinCount: 0`, so they scale to zero when idle and cost nothing; expect a few minutes between
job submission and job start while a node boots and bootstraps.

All nodes get `AmazonS3ReadOnlyAccess` so they can fetch the bootstrap script. The head node
additionally gets a scoped policy to read the database password from Secrets Manager.

## Software stack

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
| GPU | CUDA Toolkit 12.3, GPU nodes only — detected automatically via `lspci` |
| Python | python3 plus `uv` at `/usr/local/bin/uv` |

LAMMPS is not part of the bootstrap. Build it after the cluster is up — see [lammps.md](lammps.md).
