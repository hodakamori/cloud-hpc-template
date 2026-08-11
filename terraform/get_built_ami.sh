#!/usr/bin/env bash
# Terraform external data source program.
# Input  (stdin, JSON): {"region": "...", "image_id": "..."}
# Output (stdout, JSON): {"ami_id": "ami-..."}
#
# Reads the AMI id produced by `pcluster build-image` for the given image id.
# Returns an empty string if the image is not built yet.
set -euo pipefail

input=$(cat)
region=$(printf '%s' "$input" | python3 -c "import sys,json;print(json.load(sys.stdin)['region'])")
image_id=$(printf '%s' "$input" | python3 -c "import sys,json;print(json.load(sys.stdin)['image_id'])")

ami=$(pcluster describe-image --image-id "$image_id" --region "$region" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('ec2AmiInfo',{}).get('amiId',''))" 2>/dev/null || true)

python3 -c "import json,sys;print(json.dumps({'ami_id': sys.argv[1]}))" "$ami"
