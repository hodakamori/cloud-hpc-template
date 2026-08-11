# Slurm accounting

Accounting is enabled through `Scheduling/SlurmSettings/Database` in the cluster config. The head
node runs `slurmdbd`, which connects to the RDS instance over TLS and records every job.

```yaml
Scheduling:
  Scheduler: slurm
  SlurmSettings:
    Database:
      Uri: <rds-endpoint>:3306
      UserName: slurmadmin
      PasswordSecretArn: <secrets-manager-arn>
```

`DatabaseName` is deliberately left unset. `slurmdbd` then creates and owns its own database on that
server, named after the cluster via the `StorageLoc` setting, so several clusters can share one RDS
instance without colliding.

## What it enables

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

## Terraform resources

Everything lives in `terraform/rds.tf`:

| Resource | Purpose |
|----------|---------|
| `aws_subnet.private_secondary` | Second AZ, required by the DB subnet group |
| `aws_db_subnet_group.slurm_accounting` | Spans both private subnets |
| `aws_security_group.db_client` | Attached to the head node; the identity the database grants access to |
| `aws_security_group.rds` | On the instance; admits 3306 from `db_client` only |
| `aws_vpc_security_group_ingress_rule` / `egress_rule` | Standalone rules — inline blocks would form a dependency cycle between the two groups |
| `aws_db_parameter_group.slurm_accounting` | `require_secure_transport=ON`, `innodb_lock_wait_timeout=900` |
| `random_password.db` | Master password, excluding characters RDS for MySQL rejects |
| `aws_secretsmanager_secret[_version].slurm_accounting` | Password as plain text |
| `aws_db_instance.slurm_accounting` | MySQL 8.0, encrypted, Single-AZ, pinned to the primary AZ |
| `aws_iam_policy.slurm_db_secret_read` | `secretsmanager:GetSecretValue` on that secret |

### Why the password is stored as plain text

ParallelCluster reads the secret and expects its value to be the password itself, not a JSON
document. This is why the RDS-managed master password feature (`manage_master_user_password`) is not
used: it stores a JSON blob that ParallelCluster cannot parse.

The secret is created with `recovery_window_in_days = 0`, so destroying the stack deletes it
immediately. The default 30-day recovery window would keep the name reserved and make an immediate
re-apply fail.

### Why the IAM policy is explicit

ParallelCluster already grants the head node role read access to the secret named in
`PasswordSecretArn`. The template creates and attaches its own scoped policy anyway, so the grant is
explicit and does not depend on that behaviour. It is attached through
`HeadNode/Iam/AdditionalIamPolicies`.

### Parameter group choices

`require_secure_transport=ON` rejects unencrypted connections; `slurmdbd` negotiates TLS by default,
and AWS's own reference template for Slurm accounting sets the same parameter.
`innodb_lock_wait_timeout=900` follows Slurm's accounting guide, giving long-running purge and rollup
transactions room to complete. `innodb_buffer_pool_size` and `innodb_log_file_size` are left at the
RDS defaults, which already meet Slurm's recommendations.

## Connecting to the database by hand

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

## Rotating the password

Changing the secret value does **not** propagate to the cluster automatically. Stop the compute fleet
first to avoid losing accounting data, then run the ParallelCluster helper on the head node:

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

## Sizing the database

`db.t4g.micro` is sized for evaluation. ParallelCluster also recommends a larger head node when
accounting is enabled, since `slurmdbd` adds load there as well; this template keeps `t3.medium` to
hold the evaluation cost down.

```hcl
db_instance_class          = "db.t4g.small"
db_multi_az                = true
db_backup_retention_period = 30
db_skip_final_snapshot     = false
```

If `db.t4g.micro` is unavailable in your region, `db.t3.micro` is the most widely available fallback.

## Sharing one database across clusters

`slurmdbd` names its database after the cluster, so a second cluster pointed at the same RDS endpoint
gets its own separate database. Reuse `slurm_database_endpoint`, `slurm_database_username`, and
`slurm_database_secret_arn` in the other cluster's config, and attach `db_client_security_group_id`
to its head node.

AWS advises against having two clusters write to a *single* database at once, which is not what this
does — each cluster gets its own — but it does warn that a shared server concentrates load.

## Security notes

- Traffic between `slurmdbd` and the database is encrypted, but **server identity verification is not
  enabled**. For production, upload the RDS CA certificate to the head node and set `SSL_CA` in the
  `StorageParameters` of `slurmdbd.conf`.
- The database password is present in plain text in the Terraform state. Use an encrypted remote
  backend for anything shared.

## References

- [Slurm accounting with AWS ParallelCluster](https://docs.aws.amazon.com/parallelcluster/latest/ug/slurm-accounting-v3.html)
- [Scheduling section reference](https://docs.aws.amazon.com/parallelcluster/latest/ug/Scheduling-v3.html)
- [Slurm accounting](https://slurm.schedmd.com/accounting.html)
