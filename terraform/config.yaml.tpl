Region: ${region}
Image:
  Os: ubuntu2204

HeadNode:
  InstanceType: t3.medium
  Networking:
    SubnetId: ${public_subnet_id}
    ElasticIp: true
  Ssh:
    KeyName: ${key_name}
  Iam:
    AdditionalIamPolicies:
      - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
  CustomActions:
    OnNodeConfigured:
      Script: ${s3_script_path}

Scheduling:
  Scheduler: slurm
  SlurmQueues:
    - Name: cpu
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
