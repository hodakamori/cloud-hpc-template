#!/bin/bash
# Runs on the head node. Submits a small CPU batch job as each demo user, each
# charged to that user's account, so Slurm accounting records per-user usage.
set -uo pipefail

JOBDIR=/shared/jobs
sudo mkdir -p "$JOBDIR"
sudo chmod 777 "$JOBDIR"

# One shared batch script. ~90s of CPU work so sacct shows real CPU time.
cat > "$JOBDIR/demo_job.sh" <<'EOF'
#!/bin/bash
#SBATCH --job-name=acct-demo
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
#SBATCH --output=/shared/jobs/%u-%j.out

echo "user=$(whoami) host=$(hostname) account=${SLURM_JOB_ACCOUNT:-?} start=$(date)"
python3 - <<'PY'
import time, math
end = time.time() + 90
x = 0.0
while time.time() < end:
    for _ in range(100000):
        x += math.sqrt(2.0) * math.sin(x)
print("computed", x)
PY
echo "done=$(date)"
EOF
sudo chmod 644 "$JOBDIR/demo_job.sh"

echo "=== Submitting one job per user, each to its own account ==="
submit() {  # user account
    local u="$1" acct="$2"
    local jid
    jid=$(sudo -u "$u" bash -lc "cd $JOBDIR && sbatch --parsable --account=$acct demo_job.sh")
    echo "  submitted job $jid  user=$u  account=$acct"
}
submit alice physics
submit bob   physics
submit carol chemistry
submit dave  software

echo
echo "=== Current queue ==="
squeue -o "%.8i %.10u %.12a %.10P %.10T %.6M %R"
