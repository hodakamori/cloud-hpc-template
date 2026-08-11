# Optional: build a custom AMI from install_software.sh and use it as the
# compute queues' CustomAmi. Toggled by var.build_custom_ami (default false).
#
# When enabled, `terraform apply`:
#   1. resolves the official ParallelCluster base AMI (ParentImage),
#   2. renders an image-config.yaml,
#   3. runs `pcluster build-image` and waits for BUILD_COMPLETE (30-90 min),
#   4. reads back the resulting AMI id,
#   5. feeds it into the cluster config so the cpu/gpu queues launch from it.
#
# The software is baked into the image, so compute nodes no longer need to run
# apt/CUDA installs at boot. OnNodeConfigured is still kept in the cluster config
# as a safety net (e.g. GPU-only bits when the image was baked on a CPU builder).

locals {
  # A new script version produces a new image id, so changing install_software.sh
  # triggers a rebuild instead of colliding with an existing image.
  install_script_md5 = filemd5("${path.module}/../install_software.sh")
  image_id           = "${var.image_id_prefix}-${substr(local.install_script_md5, 0, 8)}"

  # Empty string when the feature is disabled -> config.yaml.tpl omits Image blocks.
  custom_ami = var.build_custom_ami ? try(data.external.built_ami[0].result.ami_id, "") : ""
}

# Resolve the official base AMI unless the user pinned one explicitly.
data "external" "official_image" {
  count   = var.build_custom_ami && var.parent_image_ami == "" ? 1 : 0
  program = ["bash", "${path.module}/get_official_ami.sh"]
  query = {
    region = var.aws_region
    os     = var.image_os
  }
}

locals {
  parent_image = var.build_custom_ami ? (
    var.parent_image_ami != "" ? var.parent_image_ami : try(data.external.official_image[0].result.ami_id, "")
  ) : ""
}

# Render the build-image configuration.
resource "local_file" "image_config" {
  count = var.build_custom_ami ? 1 : 0
  content = templatefile("${path.module}/image-config.yaml.tpl", {
    build_instance_type = var.image_builder_instance_type
    parent_image        = local.parent_image
    script_s3_path      = "s3://${aws_s3_bucket.parallelcluster.id}/${aws_s3_object.install_software.key}"
  })
  filename = "${path.module}/generated-image-config.yaml"
}

# Build the image (long-running) and wait for completion.
resource "null_resource" "build_image" {
  count = var.build_custom_ami ? 1 : 0

  triggers = {
    image_id       = local.image_id
    region         = var.aws_region
    config_content = local_file.image_config[0].content
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Building custom AMI '${local.image_id}' (this can take 30-90 minutes)..."
      pcluster build-image \
        --image-id ${local.image_id} \
        --image-configuration ${local_file.image_config[0].filename} \
        --region ${var.aws_region}

      echo "Waiting for image build to complete..."
      for i in $(seq 1 120); do
        ST=$(pcluster describe-image --image-id ${local.image_id} --region ${var.aws_region} \
              --query imageBuildStatus 2>/dev/null | tr -d '"' || echo "BUILD_IN_PROGRESS")
        echo "Attempt $i/120: imageBuildStatus = $ST"
        case "$ST" in
          BUILD_COMPLETE) echo "Image build complete"; exit 0 ;;
          BUILD_FAILED|DELETE_FAILED) echo "Image build failed"; exit 1 ;;
        esac
        sleep 60
      done
      echo "Timed out waiting for image build"; exit 1
    EOT
  }

  # Delete the image on destroy (after the cluster that uses it is gone).
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Deleting custom AMI '${self.triggers.image_id}'..."
      pcluster delete-image --image-id ${self.triggers.image_id} --region ${self.triggers.region} || true
    EOT
  }

  depends_on = [aws_s3_object.install_software]
}

# Read back the AMI id once the build has finished.
data "external" "built_ami" {
  count      = var.build_custom_ami ? 1 : 0
  program    = ["bash", "${path.module}/get_built_ami.sh"]
  depends_on = [null_resource.build_image]
  query = {
    region   = var.aws_region
    image_id = local.image_id
  }
}
