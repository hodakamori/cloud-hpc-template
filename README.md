# Cloud HPC Template

Terraform template that builds a complete HPC cluster on AWS in one command: networking, shared
storage, an AWS ParallelCluster running Slurm, and an Amazon RDS database backing Slurm accounting.
LAMMPS build and benchmark scripts are included to verify the cluster works.

## What you get

```
HeadNode  t3.medium, always on, Elastic IP, runs slurmctld + slurmdbd
  ├── cpu queue    t3.medium    × 0–2   autoscaling
  ├── gpu queue    g4dn.xlarge  × 0–2   autoscaling, NVIDIA T4
  ├── /shared      EFS, encrypted, mounted on every node
  └── accounting   RDS MySQL 8.0, reachable from the head node only
```

- **Ubuntu 22.04** with GCC 11, OpenMPI 4.1, CMake, FFTW3, and CUDA 12.3 on GPU nodes
- **Compute scales to zero** when idle, so an unused cluster costs nothing in compute
- **Job history via `sacct` / `sacctmgr` / `sreport`**, persisted in RDS and surviving head node restarts
- **Private by default** — compute nodes and the database sit in private subnets, no public IPs
- **One command to tear it all down**

Roughly **$85/month** while the stack exists, dominated by the NAT gateway, head node, and RDS.
See [docs/operations.md](docs/operations.md#cost-estimate).

## Prerequisites

Terraform >= 1.0, AWS CLI, and the ParallelCluster CLI — **`pcluster` must be on your PATH, because
Terraform invokes it**.

```bash
uv sync && source .venv/bin/activate   # installs pcluster + awscli
aws configure

terraform version && aws sts get-caller-identity && pcluster version
```

Your AWS identity needs to manage EC2, EFS, S3, RDS, Secrets Manager, CloudFormation, and IAM.
Full details in [docs/deployment.md](docs/deployment.md#iam-permissions).

## Deploy

```bash
cd terraform
terraform init
terraform apply          # ~10 min for infrastructure, then the cluster builds
```

`terraform apply` returns as soon as cluster creation *starts*. Wait for it to finish:

```bash
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1
# wait for clusterStatus: CREATE_COMPLETE  (10-12 min)

pcluster ssh --cluster-name my-cluster --region ap-northeast-1
```

Then on the head node:

```bash
sinfo                                          # both queues, nodes idle~ (powered down)
sacctmgr show cluster                          # accounting is live
srun --partition=cpu --nodes=1 --ntasks=1 hostname
```

To change region, instance types, or database sizing, copy `terraform.tfvars.example` to
`terraform.tfvars` and edit it — see [docs/deployment.md](docs/deployment.md#step-2--customize-variables-optional).

## Destroy

```bash
cd terraform
terraform destroy        # ~20 min
```

This deletes everything, **including all data in `/shared` and the accounting database**. Copy out
anything you need first, or set `db_skip_final_snapshot = false` to keep a database snapshot.

## Documentation

| Document | Contents |
|----------|----------|
| [docs/architecture.md](docs/architecture.md) | Network diagram, every AWS resource created, node and software details |
| [docs/deployment.md](docs/deployment.md) | Prerequisites, IAM, quotas, step-by-step deployment, all variables and outputs |
| [docs/slurm-accounting.md](docs/slurm-accounting.md) | How RDS is wired to Slurm, connecting to the database, password rotation, sizing |
| [docs/lammps.md](docs/lammps.md) | Building LAMMPS for CPU and GPU, MPI and scaling tests |
| [docs/operations.md](docs/operations.md) | Slurm commands, logs, config changes, cleanup, cost breakdown |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Failure modes, known caveats, verification status |

Before a real deployment, read the [known caveats](docs/troubleshooting.md#known-caveats) — notably
that the generated SSH private key and the database password are stored in plain text in the
Terraform state.

## Repository layout

```
├── install_software.sh    # Node bootstrap, run on every node via OnNodeConfigured
├── config.yaml            # Reference config for manual deployment (unused by Terraform)
├── terraform/             # All infrastructure; rds.tf holds the accounting database
├── utils/                 # LAMMPS build and benchmark scripts, run on the head node
└── docs/                  # Detailed documentation
```

## License

Provided as-is for educational and research use. Ported from the `055_parallel_cluster` example in
[hodakamori/ml-tutorial](https://github.com/hodakamori/ml-tutorial).
