#!/bin/bash
# Runs on the head node. Creates demo users (matching the UIDs the compute-node
# bootstrap uses) and builds a hierarchical Slurm accounting organization.
set -uo pipefail

# Slurm binaries are not on the default sudo PATH on ParallelCluster.
export PATH=/opt/slurm/bin:$PATH
sacctmgr() { sudo /opt/slurm/bin/sacctmgr "$@"; }

echo "=== 1. Create demo Linux users on the head node (fixed UIDs, home on /shared) ==="
sudo groupadd -g 7000 hpcusers 2>/dev/null || true
sudo mkdir -p /shared/home
for entry in "alice:7001" "bob:7002" "carol:7003" "dave:7004"; do
    u="${entry%%:*}"; uid="${entry##*:}"
    if ! id "$u" >/dev/null 2>&1; then
        sudo useradd -M -d "/shared/home/$u" -u "$uid" -g hpcusers -s /bin/bash "$u"
    fi
    if [ ! -d "/shared/home/$u" ]; then
        sudo mkdir -p "/shared/home/$u"
        sudo cp -n /etc/skel/.bash* "/shared/home/$u/" 2>/dev/null || true
    fi
    sudo chown -R "$uid:7000" "/shared/home/$u"
    sudo chmod 700 "/shared/home/$u"
done
echo "Users:"; for u in alice bob carol dave; do id "$u"; done

echo
echo "=== 2. Build the hierarchical Slurm accounting organization ==="
CLUSTER=$(sacctmgr -n show cluster format=Cluster | awk 'NF{print $1; exit}')
echo "Detected cluster name: ${CLUSTER}"

# Top-level organization account
sacctmgr -i add account company        Description="Acme Corp"           Organization=acme            || true
# Divisions (children of company)
sacctmgr -i add account research        parent=company    Description="Research Division"    Organization=acme || true
sacctmgr -i add account engineering     parent=company    Description="Engineering Division" Organization=acme || true
# Teams (children of divisions)
sacctmgr -i add account physics         parent=research      Description="Physics Team"     Organization=acme || true
sacctmgr -i add account chemistry       parent=research      Description="Chemistry Team"   Organization=acme || true
sacctmgr -i add account software        parent=engineering   Description="Software Team"    Organization=acme || true

# Associate users with their leaf accounts
sacctmgr -i add user alice  Account=physics    || true
sacctmgr -i add user bob    Account=physics    || true
sacctmgr -i add user carol  Account=chemistry  || true
sacctmgr -i add user dave   Account=software   || true

echo
echo "=== 3. Resulting account tree ==="
sacctmgr show account -s format=Account,Descr,Org,ParentName%-20 --parsable2 | column -t -s'|'
echo
echo "--- Associations (Cluster / Account hierarchy / User) ---"
sacctmgr show assoc format=Cluster,Account%-14,ParentName%-14,User%-10 tree
echo
echo "Head-node setup complete."
