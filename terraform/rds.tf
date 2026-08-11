# Amazon RDS for MySQL, used as the backing store for Slurm accounting.
#
# ParallelCluster runs slurmdbd on the head node and points it at this database
# (Scheduling/SlurmSettings/Database). slurmdbd creates and owns one database per
# cluster, named after the cluster, so no initial database is created here.

resource "random_id" "db_suffix" {
  byte_length = 4
}

# Second private subnet. RDS requires a DB subnet group spanning at least two
# Availability Zones even for a Single-AZ instance, so this subnet exists purely
# to satisfy that requirement. Compute nodes stay in the primary private subnet
# because the EFS mount target only lives in the primary AZ.
resource "aws_subnet" "private_secondary" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_secondary_cidr
  availability_zone = var.availability_zone_secondary

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-private-subnet-secondary"
    }
  )
}

resource "aws_route_table_association" "private_secondary" {
  subnet_id      = aws_subnet.private_secondary.id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "slurm_accounting" {
  name = "${var.project_name}-slurm-accounting"
  subnet_ids = [
    aws_subnet.private.id,
    aws_subnet.private_secondary.id
  ]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-db-subnet-group"
    }
  )
}

# Security group attached to the head node via HeadNode/Networking/
# AdditionalSecurityGroups. It carries no permissions of its own beyond egress to
# the database; its purpose is to act as the identity the database grants access
# to, so only the head node can reach the DB port.
resource "aws_security_group" "db_client" {
  name        = "${var.project_name}-db-client-sg"
  description = "Attached to the head node to grant access to the Slurm accounting database"
  vpc_id      = aws_vpc.main.id

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-db-client-sg"
    }
  )
}

# Security group on the RDS instance itself.
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for the Slurm accounting RDS instance"
  vpc_id      = aws_vpc.main.id

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-rds-sg"
    }
  )
}

# The two groups reference each other, so the rules are declared as standalone
# resources. Inline ingress/egress blocks would create a dependency cycle.
resource "aws_vpc_security_group_ingress_rule" "rds_from_client" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from the cluster head node"
  referenced_security_group_id = aws_security_group.db_client.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "client_to_rds" {
  security_group_id            = aws_security_group.db_client.id
  description                  = "MySQL to the Slurm accounting database"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

# Parameter group. The two non-default settings match AWS's reference Slurm
# accounting template:
#   require_secure_transport  - reject unencrypted connections. slurmdbd
#                               negotiates TLS by default, so this is safe.
#   innodb_lock_wait_timeout  - Slurm's accounting guide recommends 900s to
#                               survive long-running purge/rollup transactions.
# innodb_buffer_pool_size and innodb_log_file_size are left at the RDS defaults,
# which already meet Slurm's recommendations.
resource "aws_db_parameter_group" "slurm_accounting" {
  name_prefix = "${var.project_name}-slurm-accounting-"
  family      = var.db_parameter_group_family
  description = "Slurm accounting tuning for slurmdbd"

  parameter {
    name         = "require_secure_transport"
    value        = "ON"
    apply_method = "immediate"
  }

  parameter {
    name         = "innodb_lock_wait_timeout"
    value        = "900"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-slurm-accounting-pg"
    }
  )
}

# Master password. RDS for MySQL rejects '/', '"', '@', and spaces in passwords;
# quotes and backslashes are also excluded to keep the value safe to paste.
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ParallelCluster reads this secret and expects the secret value to be the
# password itself as plain text, not a JSON document. This is why the RDS-managed
# master password feature (manage_master_user_password) is not used: it stores a
# JSON blob that ParallelCluster cannot parse.
resource "aws_secretsmanager_secret" "slurm_accounting" {
  name_prefix = "${var.project_name}-slurm-accounting-"
  description = "Master password for the Slurm accounting database"

  # Without this, a destroyed secret is only scheduled for deletion and its name
  # stays reserved, which makes an immediate re-apply fail.
  recovery_window_in_days = 0

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-slurm-accounting-secret"
    }
  )
}

resource "aws_secretsmanager_secret_version" "slurm_accounting" {
  secret_id     = aws_secretsmanager_secret.slurm_accounting.id
  secret_string = random_password.db.result
}

resource "aws_db_instance" "slurm_accounting" {
  identifier = "${var.project_name}-slurm-accounting-${random_id.db_suffix.hex}"

  engine               = "mysql"
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.slurm_accounting.name

  # slurmdbd creates its own per-cluster database, so no initial db_name is set.
  username = var.db_username
  password = random_password.db.result
  port     = var.db_port

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.slurm_accounting.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  # Keep a Single-AZ instance in the same AZ as the head node, otherwise RDS may
  # place it in the secondary AZ and every slurmdbd query crosses an AZ boundary.
  # Multi-AZ manages placement itself and rejects an explicit AZ.
  availability_zone = var.db_multi_az ? null : var.availability_zone

  backup_retention_period    = var.db_backup_retention_period
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = true

  enabled_cloudwatch_logs_exports = ["error"]

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = "${var.project_name}-slurm-accounting-final-${random_id.db_suffix.hex}"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-slurm-accounting"
    }
  )
}

# ParallelCluster already grants the head node role read access to the secret
# named in PasswordSecretArn. This policy makes that grant explicit and
# independent of that behaviour, and is attached through
# HeadNode/Iam/AdditionalIamPolicies.
resource "aws_iam_policy" "slurm_db_secret_read" {
  name_prefix = "${var.project_name}-slurm-db-secret-"
  description = "Allows the cluster head node to read the Slurm accounting database password"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.slurm_accounting.arn
      }
    ]
  })

  tags = var.tags
}
