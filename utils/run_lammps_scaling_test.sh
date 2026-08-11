#!/bin/bash
# LAMMPS Scaling Test Suite
# Tests performance with different numbers of MPI processes

echo "=========================================="
echo "LAMMPS Scaling Test Suite"
echo "=========================================="
echo "This will submit multiple jobs to test scaling performance"
echo ""

# Create results directory
RESULTS_DIR="/shared/lammps_scaling_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p ${RESULTS_DIR}

echo "Results will be saved to: ${RESULTS_DIR}"
echo ""

# Test configurations: nodes, tasks
CONFIGS=(
    "1 1"    # 1 node, 1 task
    "1 2"    # 1 node, 2 tasks
    "2 2"    # 2 nodes, 2 tasks (1 per node)
    "2 4"    # 2 nodes, 4 tasks (2 per node)
)

# Submit jobs for each configuration
for config in "${CONFIGS[@]}"; do
    read nodes tasks <<< "$config"

    JOB_NAME="lammps_n${nodes}_t${tasks}"

    echo "Submitting: ${nodes} nodes, ${tasks} tasks"

    # Create job script
    cat > ${RESULTS_DIR}/${JOB_NAME}.sh << EOF
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --partition=cpu
#SBATCH --nodes=${nodes}
#SBATCH --ntasks=${tasks}
#SBATCH --cpus-per-task=1
#SBATCH --time=00:30:00
#SBATCH --output=${RESULTS_DIR}/${JOB_NAME}_%j.out
#SBATCH --error=${RESULTS_DIR}/${JOB_NAME}_%j.err

set -e

echo "Configuration: ${nodes} nodes, ${tasks} tasks"
echo "Job ID: \$SLURM_JOB_ID"
echo "Started: \$(date)"

# Load LAMMPS environment
source /shared/lammps/cpu-env.sh

# Working directory
WORK_DIR="${RESULTS_DIR}/${JOB_NAME}_\${SLURM_JOB_ID}"
mkdir -p \${WORK_DIR}
cd \${WORK_DIR}

# Copy input file
cp /home/ubuntu/lammps_test_input.lmp ./input.lmp

# Run LAMMPS
mpirun -np \$SLURM_NTASKS lmp -in input.lmp -log lammps.log

echo "Completed: \$(date)"

# Extract performance
if [ -f lammps.log ]; then
    echo "" >> ${RESULTS_DIR}/summary.txt
    echo "=== ${nodes} nodes, ${tasks} tasks (Job \$SLURM_JOB_ID) ===" >> ${RESULTS_DIR}/summary.txt
    grep "Loop time" lammps.log >> ${RESULTS_DIR}/summary.txt || echo "No timing data" >> ${RESULTS_DIR}/summary.txt
fi
EOF

    # Submit the job
    sbatch ${RESULTS_DIR}/${JOB_NAME}.sh

    # Wait a bit between submissions
    sleep 2
done

echo ""
echo "=========================================="
echo "All jobs submitted!"
echo "=========================================="
echo ""
echo "Monitor jobs with: squeue"
echo "View results: cat ${RESULTS_DIR}/summary.txt"
echo "Individual logs: ls ${RESULTS_DIR}/*.out"
