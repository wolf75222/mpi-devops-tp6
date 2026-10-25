#!/usr/bin/env bash
# Installe l'env Spack depuis spack.lock, sur un nœud de calcul pour ne rien
# récupérer du login. Ne recompile que ce qui manque.
#SBATCH --job-name=spack-env-tp6
#SBATCH --account=r260105
#SBATCH --partition=instant
#SBATCH --constraint=x64cpu
#SBATCH --nodes=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=16G
#SBATCH --time=00:45:00
#SBATCH --output=spack-install-%j.out
set -euo pipefail
romeo_load_x64cpu_env
spack install patch   # patch n'existe pas sur les nœuds de calcul
spack load patch
spack -e spack install -j "$SLURM_CPUS_PER_TASK"
spack -e spack find -l
