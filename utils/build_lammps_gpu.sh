#!/bin/bash
#SBATCH --job-name=build_lammps_gpu
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=02:00:00
#SBATCH --output=/shared/lammps_gpu_build_%j.out
#SBATCH --error=/shared/lammps_gpu_build_%j.err

set -e

# LAMMPS Build Script (GPU version - Kokkos CUDA)
# Run as a job on GPU node
#
# Kokkos_ARCH_TURING75 matches the NVIDIA T4 in g4dn instances (compute 7.5).
# Change it if the gpu queue uses a different instance type, e.g.
#   p3 (V100)  -> Kokkos_ARCH_VOLTA70
#   g5 (A10G)  -> Kokkos_ARCH_AMPERE86

BUILD_LOG=/shared/lammps_gpu_build.log
exec > >(tee -a ${BUILD_LOG}) 2>&1

echo "=========================================="
echo "LAMMPS GPU Build Started: $(date)"
echo "=========================================="
echo "Running on: $(hostname)"

# Check build environment
echo "GCC version:"
gcc --version | head -1

echo "CMake version:"
cmake --version | head -1

echo "CUDA version:"
nvcc --version 2>&1 | grep "release" || echo "CUDA not found"

echo "GPU information:"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv

# Clone LAMMPS (assuming already cloned on HeadNode)
cd /shared
if [ ! -d "lammps" ]; then
    echo "Cloning LAMMPS..."
    git clone --depth 1 https://github.com/lammps/lammps.git
    echo "Clone completed"
fi

# Prepare build directory
cd /shared/lammps
rm -rf build-gpu
mkdir -p build-gpu
cd build-gpu

echo "=========================================="
echo "Configuring CMake (GPU - Kokkos CUDA)..."
echo "=========================================="

cmake \
    -DCMAKE_INSTALL_PREFIX=/shared/lammps/gpu \
    -DCMAKE_BUILD_TYPE=Release \
    -DPKG_KOKKOS=ON \
    -DKokkos_ENABLE_CUDA=ON \
    -DKokkos_ARCH_TURING75=ON \
    -DPKG_MOLECULE=ON \
    -DPKG_KSPACE=ON \
    -DPKG_RIGID=ON \
    -DPKG_MANYBODY=ON \
    -DBUILD_MPI=ON \
    -DBUILD_OMP=ON \
    ../cmake

echo "=========================================="
echo "Building (parallel compilation)..."
echo "=========================================="

# Display number of available cores
NPROC=$(nproc)
echo "Using $NPROC cores"

make -j${NPROC}

echo "=========================================="
echo "Installing..."
echo "=========================================="

make install

# Create environment setup script
cat > /shared/lammps/gpu-env.sh << 'EOF'
# LAMMPS GPU environment variables
export PATH=/shared/lammps/gpu/bin:$PATH
export LD_LIBRARY_PATH=/shared/lammps/gpu/lib:$LD_LIBRARY_PATH
export CUDA_HOME=/usr/local/cuda
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH
EOF

echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo "Install location: /shared/lammps/gpu"
echo "Environment setup: source /shared/lammps/gpu-env.sh"
echo ""
echo "Verification commands (on GPU node):"
echo "  source /shared/lammps/gpu-env.sh"
echo "  lmp -h"
echo ""
echo "Build log: ${BUILD_LOG}"
echo "Completed: $(date)"
