Region: ${region}
Image:
  Os: ubuntu2204

HeadNode:
  InstanceType: t3.medium
  Networking:
    SubnetId: ${public_subnet_id}
    ElasticIp: true
    # Grants the head node access to the Slurm accounting database. Compute nodes
    # do not need it: only the head node runs slurmdbd.
    AdditionalSecurityGroups:
      - ${db_client_security_group_id}
  Ssh:
    KeyName: ${key_name}
  Iam:
    AdditionalIamPolicies:
      - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
      - Policy: ${slurm_db_secret_policy_arn}
  CustomActions:
    OnNodeConfigured:
      Script: ${s3_script_path}

Scheduling:
  Scheduler: slurm
  SlurmSettings:
    # slurmdbd runs on the head node and stores accounting data in this database.
    # It creates its own database named after the cluster, so no DatabaseName is
    # set here.
    Database:
      Uri: ${slurm_database_uri}
      UserName: ${slurm_database_user}
      PasswordSecretArn: ${slurm_database_secret_arn}
  SlurmQueues:
    - Name: cpu
%{ if custom_ami != "" ~}
      # Queue-level custom AMI, built from install_software.sh by pcluster build-image.
      Image:
        CustomAmi: ${custom_ami}
%{ endif ~}
      ComputeResources:
        - Name: t3medium
          InstanceType: t3.medium
          MinCount: 0
          MaxCount: 2
      Networking:
        SubnetIds:
          - ${private_subnet_id}
      Iam:
        AdditionalIamPolicies:
          - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
      CustomActions:
        OnNodeConfigured:
          Script: ${s3_script_path}
    - Name: gpu
%{ if custom_ami != "" ~}
      Image:
        CustomAmi: ${custom_ami}
%{ endif ~}
      ComputeResources:
        - Name: g4dnxlarge
          InstanceType: g4dn.xlarge
          MinCount: 0
          MaxCount: 2
      Networking:
        SubnetIds:
          - ${private_subnet_id}
      Iam:
        AdditionalIamPolicies:
          - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
      CustomActions:
        OnNodeConfigured:
          Script: ${s3_script_path}

SharedStorage:
  - MountDir: /shared
    Name: efs-shared
    StorageType: Efs
    EfsSettings:
      FileSystemId: ${efs_id}
