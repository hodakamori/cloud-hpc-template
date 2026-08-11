#!/bin/bash
set -e

# LAMMPS Build Script (CPU version - Kokkos OpenMP)
# Run on HeadNode

BUILD_LOG=/shared/lammps_cpu_build.log
exec > >(tee -a ${BUILD_LOG}) 2>&1

echo "=========================================="
echo "LAMMPS CPU Build Started: $(date)"
echo "=========================================="

# Check build environment
echo "GCC version:"
gcc --version | head -1

echo "CMake version:"
cmake --version | head -1

echo "MPI version:"
mpirun --version 2>&1 | head -1 || echo "MPI not found in PATH"

# Clone LAMMPS
cd /shared
if [ -d "lammps" ]; then
    echo "LAMMPS directory already exists. Skipping clone."
    echo "To re-clone, run: rm -rf /shared/lammps"
else
    echo "Cloning LAMMPS..."
    git clone --depth 1 https://github.com/lammps/lammps.git
    echo "Clone completed"
fi

# Prepare build directory
cd /shared/lammps
rm -rf build-cpu
mkdir -p build-cpu
cd build-cpu

echo "=========================================="
echo "Configuring CMake (CPU - Kokkos OpenMP)..."
echo "=========================================="

cmake \
    -DCMAKE_INSTALL_PREFIX=/shared/lammps/cpu \
    -DCMAKE_BUILD_TYPE=Release \
    -DPKG_KOKKOS=ON \
    -DKokkos_ENABLE_OPENMP=ON \
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
cat > /shared/lammps/cpu-env.sh << 'EOF'
# LAMMPS CPU environment variables
export PATH=/shared/lammps/cpu/bin:$PATH
export LD_LIBRARY_PATH=/shared/lammps/cpu/lib:$LD_LIBRARY_PATH
EOF

echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo "Install location: /shared/lammps/cpu"
echo "Environment setup: source /shared/lammps/cpu-env.sh"
echo ""
echo "Verification commands:"
echo "  source /shared/lammps/cpu-env.sh"
echo "  lmp -h"
echo ""
echo "Build log: ${BUILD_LOG}"
echo "Completed: $(date)"
