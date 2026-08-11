#!/bin/bash
#SBATCH --job-name=lammps_mpi_test
#SBATCH --partition=cpu
#SBATCH --nodes=2                    # Use 2 compute nodes
#SBATCH --ntasks=4                   # Total 4 MPI processes (2 per node)
#SBATCH --cpus-per-task=1
#SBATCH --time=00:30:00
#SBATCH --output=lammps_test_%j.out
#SBATCH --error=lammps_test_%j.err

set -e

echo "=========================================="
echo "LAMMPS MPI Parallel Test"
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Started: $(date)"
echo "Running on: $(hostname)"
echo ""
echo "Slurm Configuration:"
echo "  Nodes: $SLURM_JOB_NUM_NODES"
echo "  Total tasks: $SLURM_NTASKS"
echo "  CPUs per task: $SLURM_CPUS_PER_TASK"
echo "  Nodelist: $SLURM_JOB_NODELIST"
echo ""

# Load LAMMPS environment
source /shared/lammps/cpu-env.sh

# Verify LAMMPS is available
echo "LAMMPS executable: $(which lmp)"
echo "LAMMPS version:"
lmp -help | head -5
echo ""

# Display MPI information
echo "MPI Configuration:"
echo "  MPI version: $(mpirun --version 2>&1 | head -1)"
echo ""

# Create working directory for this job
WORK_DIR="/shared/lammps_jobs/${SLURM_JOB_ID}"
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}

# Copy input file
cp /home/ubuntu/lammps_test_input.lmp ./input.lmp

echo "Working directory: ${WORK_DIR}"
echo "=========================================="
echo "Starting LAMMPS simulation..."
echo "=========================================="

# Run LAMMPS with MPI
# -np $SLURM_NTASKS uses the number of tasks specified in SBATCH
mpirun -np $SLURM_NTASKS lmp -in input.lmp -log lammps.log

echo ""
echo "=========================================="
echo "Simulation Completed"
echo "=========================================="
echo "Ended: $(date)"

# Display performance summary
if [ -f lammps.log ]; then
    echo ""
    echo "Performance Summary:"
    echo "-------------------"
    grep -A 10 "Loop time" lammps.log || echo "Performance data not found"
    echo ""
    echo "MPI Breakdown:"
    grep -A 20 "MPI task timing breakdown" lammps.log || echo "MPI timing data not found"
fi

echo ""
echo "Output files are in: ${WORK_DIR}"
echo "  - lammps.log (main log)"
echo "  - input.lmp (input file)"
