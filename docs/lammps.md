# Running LAMMPS

The scripts in `utils/` run on the head node. Copy them over or clone this repository there.

```bash
scp -i pcluster-key-ed25519.pem -r utils ubuntu@<HeadNode-IP>:~/
```

## Preparing `/shared`

`/shared` (EFS) is owned by root initially, so grant write access before building.

```bash
sudo chown ubuntu:ubuntu /shared
sudo mkdir -p /shared/lammps_jobs
sudo chown ubuntu:ubuntu /shared/lammps_jobs

# The MPI test job reads its input from the home directory
cp ~/utils/lammps_test_input.lmp ~/lammps_test_input.lmp
```

## Building the CPU version

```bash
./utils/build_lammps_cpu.sh
```

- Clones LAMMPS to `/shared/lammps`, builds in `build-cpu`, installs to `/shared/lammps/cpu`
- Enabled packages: `KOKKOS` (OpenMP), `MOLECULE`, `KSPACE`, `RIGID`, `MANYBODY`, MPI, OpenMP
- Log: `/shared/lammps_cpu_build.log`
- **The head node has only 2 vCPUs, so this can take 30 minutes or more.** Run it inside `tmux` or
  `screen`, or submit it as a batch job.

```bash
source /shared/lammps/cpu-env.sh
lmp -h
```

## Building the GPU version

CUDA and a GPU are required, so this is submitted to the GPU queue.

```bash
sbatch utils/build_lammps_gpu.sh

squeue
tail -f /shared/lammps_gpu_build_*.out
```

- Installs to `/shared/lammps/gpu`, environment script at `/shared/lammps/gpu-env.sh`
- The Kokkos GPU architecture is set to `Kokkos_ARCH_TURING75`, matching the NVIDIA T4 in `g4dn`
  instances. Change it if you switch instance types:

  | Instance family | GPU | Kokkos arch |
  |-----------------|-----|-------------|
  | `g4dn` | NVIDIA T4 | `Kokkos_ARCH_TURING75` |
  | `p3` | NVIDIA V100 | `Kokkos_ARCH_VOLTA70` |
  | `g5` | NVIDIA A10G | `Kokkos_ARCH_AMPERE86` |

## MPI test

```bash
sbatch utils/run_lammps_mpi_test.sh

squeue
watch -n 5 sinfo
cat lammps_test_*.out
```

Runs a Lennard-Jones fluid benchmark (32,000 atoms, 5,000 steps) across 2 nodes and 4 MPI ranks.
The working directory is `/shared/lammps_jobs/<JOB_ID>`. The job reads
`/home/ubuntu/lammps_test_input.lmp`, so do not skip the copy step above.

## Scaling test

```bash
./utils/run_lammps_scaling_test.sh
```

Submits four configurations and collects `Loop time` for each:

| Nodes | MPI ranks |
|-------|-----------|
| 1 | 1 |
| 1 | 2 |
| 2 | 2 |
| 2 | 4 |

```bash
cat /shared/lammps_scaling_results_*/summary.txt

# With accounting enabled, compare runtimes directly
sacct --format=JobID,JobName,NNodes,NTasks,Elapsed,State
```

> The `cpu` queue caps at 2 nodes, so the two-node configurations queue rather than run concurrently.

## Troubleshooting builds

```bash
cat /shared/lammps_cpu_build.log
cat /shared/lammps_gpu_build.log

gcc --version     # 11.x
cmake --version   # 3.22.x
mpirun --version  # 4.1.x
nvcc --version    # 12.3 on GPU nodes
nvidia-smi
```

The head node has 4 GiB of RAM, so a parallel compile can be killed by the OOM killer. Fall back to
`make -j1` or build on a larger instance.
