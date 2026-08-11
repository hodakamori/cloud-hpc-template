#!/usr/bin/env bash
# Terraform external data source program.
# Input  (stdin, JSON): {"region": "...", "os": "..."}
# Output (stdout, JSON): {"ami_id": "ami-..."}
#
# Resolves the official ParallelCluster base AMI for the given OS/region, used
# as the ParentImage for `pcluster build-image`.
set -euo pipefail

input=$(cat)
region=$(printf '%s' "$input" | python3 -c "import sys,json;print(json.load(sys.stdin)['region'])")
os=$(printf '%s' "$input" | python3 -c "import sys,json;print(json.load(sys.stdin)['os'])")

ami=$(pcluster list-official-images --region "$region" --os "$os" 2>/dev/null \
  | python3 -c "import sys,json;imgs=json.load(sys.stdin).get('images',[]);print(imgs[0]['amiId'] if imgs else '')")

python3 -c "import json,sys;print(json.dumps({'ami_id': sys.argv[1]}))" "$ami"
