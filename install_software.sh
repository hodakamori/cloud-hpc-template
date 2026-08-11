#!/bin/bash
set -e

# Log file
LOG_FILE=/var/log/parallelcluster/install_software.log
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "Starting software installation at $(date)"

# Detect if this is a GPU node
if lspci | grep -i nvidia > /dev/null 2>&1; then
    IS_GPU_NODE=true
    echo "Detected GPU node"
else
    IS_GPU_NODE=false
    echo "Detected CPU node"
fi

# Update package list
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Install system dependencies
echo "Installing system dependencies..."
apt-get install -y \
    build-essential \
    cmake \
    wget \
    git \
    libopenmpi-dev \
    openmpi-bin \
    libfftw3-dev \
    python3 \
    python3-dev \
    libssl-dev

# MPI is already in PATH on Ubuntu with openmpi-bin package
echo "MPI setup completed (already in PATH)"

# Install CUDA if GPU node
if [ "$IS_GPU_NODE" = true ]; then
    echo "Installing CUDA..."

    # Install CUDA repository
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt-get update -y

    # Install CUDA toolkit
    apt-get install -y cuda-toolkit-12-3

    # Set up CUDA environment
    echo "export PATH=/usr/local/cuda/bin:\$PATH" >> /etc/profile.d/cuda.sh
    echo "export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH" >> /etc/profile.d/cuda.sh
    source /etc/profile.d/cuda.sh

    echo "CUDA installation completed"
fi

# Install uv for all users
echo "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
cp ~/.local/bin/uv /usr/local/bin/
chmod 755 /usr/local/bin/uv
echo "uv installation completed"

echo "Software installation completed at $(date)"
echo "uv installed at: /usr/local/bin/uv"
echo "build-essential, cmake, openmpi installed via apt"
