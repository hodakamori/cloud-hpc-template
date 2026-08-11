# ParallelCluster build-image configuration, rendered by Terraform.
# `pcluster build-image` bakes install_software.sh into a custom AMI on top of
# the official ParallelCluster base AMI, so compute nodes boot with the software
# already present instead of installing it via OnNodeConfigured at boot time.
Build:
  InstanceType: ${build_instance_type}
  ParentImage: ${parent_image}
  UpdateOsPackages:
    Enabled: true
  # The build instance needs to read the component script from the private
  # S3 bucket.
  Iam:
    AdditionalIamPolicies:
      - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
  Components:
    # The exact same script the cluster otherwise runs as OnNodeConfigured.
    - Type: script
      Value: ${script_s3_path}
