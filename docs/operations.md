# Operations

## Slurm commands

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

## Logs

```bash
pcluster list-cluster-log-streams --cluster-name my-cluster --region ap-northeast-1
pcluster get-cluster-log-events --cluster-name my-cluster \
  --log-stream-name <stream-name> --region ap-northeast-1
```

On the nodes:

| Path | Contents |
|------|----------|
| `/var/log/parallelcluster/install_software.log` | This template's bootstrap script |
| `/var/log/parallelcluster/clustermgtd` | Autoscaling, head node |
| `/var/log/slurmctld.log` | Slurm controller |
| `/var/log/slurmdbd.log` | Accounting daemon — first place to look for database issues |

## Applying configuration changes

Editing `terraform/config.yaml.tpl` (instance types, node counts, and so on) changes the
`null_resource` trigger, so `terraform apply` **deletes and recreates the cluster**. Data in
`/shared` (EFS) and the accounting database survive, because both are separate Terraform resources.

For queue or node count changes alone, stopping the compute fleet and running
`pcluster update-cluster` is much faster.

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
  (see [lammps.md](lammps.md))

### Adding software to the bootstrap

Edit `install_software.sh` and run `terraform apply`. The S3 object's `etag` changes, which
recreates the cluster and applies the new script.

### Manual deployment

The `config.yaml` at the repository root is a reference for running `pcluster create-cluster` by hand
against pre-existing infrastructure. Replace every `<...>` placeholder with real values; Terraform
does not use this file.

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
> ⚠️ **The accounting database is destroyed too.** `db_skip_final_snapshot` defaults to `true`, so no
> snapshot is kept. Set it to `false` if you want the job history retained.
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

## Cost estimate

Rough figures for ap-northeast-1. **Verify against the
[AWS pricing pages](https://aws.amazon.com/pricing/) before relying on them** — these are approximate
and change over time.

### Always on, while the stack exists

| Item | Approximate rate | Approximate monthly |
|------|------------------|---------------------|
| NAT Gateway | ~$0.045/hr plus data processing | ~$33 |
| HeadNode (`t3.medium`) | ~$0.0416/hr | ~$30 |
| RDS (`db.t4g.micro`, Single-AZ) | ~$0.02/hr | ~$15 |
| RDS storage (20 GiB gp3) + backups | ~$0.14/GiB-month | ~$3 |
| Elastic IPs ×2 | low while attached | a few dollars |
| **Subtotal** | | **~$85/month** |

### Only while jobs run

| Item | Approximate rate |
|------|------------------|
| CPU node (`t3.medium`) | ~$0.0416/hr per node |
| GPU node (`g4dn.xlarge`) | ~$0.526/hr per node |

### Storage

| Item | Approximate rate |
|------|------------------|
| EFS standard | ~$0.30/GB-month, dropping after the 30-day IA transition |
| S3 | ~$0.025/GB-month, negligible for scripts |

### Keeping costs down

- Compute nodes use `MinCount: 0`, so an idle cluster costs nothing in compute
- Destroying the stack when idle is by far the biggest saving — it removes the NAT gateway and RDS
- Setting `db_backup_retention_period = 0` and shrinking `db_allocated_storage` trims the database cost
- The S3 gateway VPC endpoint already avoids NAT data processing charges for S3 traffic
