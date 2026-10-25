#!/usr/bin/env bash
# Test MPI sur 2 nœuds / 8 tâches. Pas de partition debug sur ROMEO : instant (1 h max).
#SBATCH --job-name=ci-mpi-bcast
#SBATCH --account=r260105
#SBATCH --partition=instant
#SBATCH --constraint=x64cpu
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --ntasks-per-node=4
#SBATCH --mem=2G
#SBATCH --time=00:05:00
#SBATCH --output=ci-%j.out
#SBATCH --error=ci-%j.out
set -euo pipefail

# pas de Lmod sur ROMEO : env ROMEO puis env Spack du dépôt (installé par spack_install.sh)
romeo_load_x64cpu_env
spack env activate -d spack
command -v mpicc >/dev/null || { echo "env Spack absent, lancer ci/spack_install.sh"; exit 3; }
echo "env: spack env $(pwd)/spack"
echo "mpicc: $(which mpicc) ($(mpicc --version | head -1))"

# compilé ici, sur le nœud de calcul, avec l'OpenMPI de ROMEO
cmake -S . -B build-$SLURM_JOB_ID
cmake --build build-$SLURM_JOB_ID -j 4

echo "nodes: $SLURM_JOB_NODELIST"
srun ./build-$SLURM_JOB_ID/bcast_test
echo SUCCESS
