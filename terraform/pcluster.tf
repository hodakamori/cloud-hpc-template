# Generate ParallelCluster config.yaml from template
resource "local_file" "pcluster_config" {
  content = templatefile("${path.module}/config.yaml.tpl", {
    region            = var.aws_region
    public_subnet_id  = aws_subnet.public.id
    private_subnet_id = aws_subnet.private.id
    key_name          = aws_key_pair.pcluster.key_name
    s3_script_path    = "s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}"
    efs_id            = aws_efs_file_system.shared.id
  })
  filename = "${path.module}/generated-config.yaml"

  depends_on = [
    aws_efs_mount_target.private,
    aws_s3_object.install_software
  ]
}

# Create ParallelCluster
resource "null_resource" "pcluster_create" {
  triggers = {
    cluster_name   = var.cluster_name
    config_content = local_file.pcluster_config.content
    region         = var.aws_region
  }

  # Create cluster
  provisioner "local-exec" {
    command = <<-EOT
      echo "Creating ParallelCluster: ${var.cluster_name}..."
      pcluster create-cluster \
        --cluster-name ${var.cluster_name} \
        --cluster-configuration ${local_file.pcluster_config.filename} \
        --region ${var.aws_region}

      echo "Waiting for cluster creation to complete..."
      pcluster describe-cluster \
        --cluster-name ${var.cluster_name} \
        --region ${var.aws_region}
    EOT
  }

  # Delete cluster on destroy
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Deleting ParallelCluster: ${self.triggers.cluster_name}..."
      pcluster delete-cluster \
        --cluster-name ${self.triggers.cluster_name} \
        --region ${self.triggers.region} || true

      echo "Waiting for cluster deletion to complete (this may take 5-10 minutes)..."

      # Wait for cluster to be deleted
      for i in {1..60}; do
        STATUS=$(pcluster describe-cluster \
          --cluster-name ${self.triggers.cluster_name} \
          --region ${self.triggers.region} \
          --query 'clusterStatus' \
          --output text 2>/dev/null || echo "DELETED")

        echo "Attempt $i/60: Cluster status = $STATUS"

        if [ "$STATUS" = "DELETED" ] || [ "$STATUS" = "DELETE_COMPLETE" ]; then
          echo "Cluster deleted successfully"
          break
        fi

        if [ $i -eq 60 ]; then
          echo "Warning: Timeout waiting for cluster deletion. Proceeding anyway..."
          break
        fi

        sleep 10
      done

      echo "Cluster deletion process completed"
    EOT
  }

  depends_on = [
    local_file.pcluster_config,
    aws_vpc_endpoint.s3,
    aws_nat_gateway.main
  ]
}

