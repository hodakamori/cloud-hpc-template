# Troubleshooting

## `terraform apply` fails with `pcluster: command not found`

The `pcluster` CLI must be on the PATH of the machine running Terraform.

```bash
uv sync && source .venv/bin/activate
pcluster version
```

## Cluster reaches `CREATE_FAILED`

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

## `sacct` reports that accounting is not enabled

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
3. **TLS** — the parameter group sets `require_secure_transport=ON`, which rejects unencrypted
   connections. `slurmdbd` negotiates TLS by default, but a manual `mysql` client without
   `--ssl-mode=REQUIRED` will be refused. If `slurmdbd.log` shows
   *"Connections using insecure transport are prohibited"*, set that parameter to `OFF` in
   `terraform/rds.tf` and re-apply.
4. **Database reachability** — the RDS instance must be `available` in the console.

## Compute nodes never start, or immediately fail

```bash
sinfo -R
sudo tail -f /var/log/parallelcluster/clustermgtd
```

Usually insufficient capacity for the instance type, or a quota limit.

## RDS creation fails

- **Instance class unavailable** — `db.t4g.micro` is not offered for MySQL 8.0 in every region.
  Set `db_instance_class = "db.t3.micro"`.
- **Engine version mismatch** — `db_parameter_group_family` must match `db_engine_version`
  (`mysql8.0` for `8.0`).
- **Secret name already exists** — should not happen, since the secret uses a generated name prefix
  and `recovery_window_in_days = 0`, but a secret deleted outside Terraform may still be in its
  recovery window. Force-delete it:
  `aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery`.

## Cannot write to `/shared`

```bash
sudo chown ubuntu:ubuntu /shared
sudo chown -R ubuntu:ubuntu /shared/lammps /shared/lammps_jobs
```

## LAMMPS build failures

See [lammps.md](lammps.md#troubleshooting-builds).

## `terraform destroy` fails on the VPC

The cluster deletion poll times out after 10 minutes and Terraform proceeds anyway, which can leave
the VPC with dependent resources still attached. Wait for the cluster to finish deleting, then run
`terraform destroy` again.

## Terraform state drift

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

# Known caveats

- **`terraform apply` does not wait for the cluster.** `pcluster create-cluster` is invoked without
  `--wait`, so a successful apply does not mean the cluster is usable, and an asynchronous cluster
  failure will not fail the apply. Poll `describe-cluster`.
- **The SSH private key is written to the repository root in plain text**
  (`pcluster-key-ed25519.pem`). The root `.gitignore` excludes `*.pem`, but be careful not to commit
  it. The key is also stored in plain text in the Terraform state, as is the database password —
  treat `terraform.tfstate` as a secret and use an encrypted remote backend for anything shared.
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

# Verification status

The configuration passes the following static checks:

| Check | Result |
|-------|--------|
| `terraform validate` and `terraform fmt -check` | Pass |
| `terraform plan` (offline, mock credentials) | Pass, 38 resources |
| Rendered cluster config loaded through the real ParallelCluster 3.14.1 `ClusterSchema` | Pass |
| `Uri` format against ParallelCluster's `DatabaseUriValidator` | Accepted |
| Shell syntax, YAML parsing | Pass |

It has **not** been deployed to AWS, so anything that only surfaces at the AWS API or runtime level
is unproven — RDS instance class availability per region, reaching `CREATE_COMPLETE`, the
`slurmdbd` TLS handshake against RDS MySQL, and the LAMMPS builds.
