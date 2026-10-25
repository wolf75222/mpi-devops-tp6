# mpi-devops-tp6

TP du Cours 6, DevOps pour le HPC (M2 CHPS, CHPS0902).

Un petit test MPI (`MPI_Bcast`) passé dans une CI : build et test en conteneur, lint sur les PR, tarball sur les tags, puis test sur 2 nœuds de ROMEO via Slurm, avec un environnement Spack versionné.

Le compte rendu est dans [`carnet-de-bord.md`](carnet-de-bord.md).

## Fichiers

- `src/bcast_test.c`, `CMakeLists.txt` : le code et le test CTest
- `.gitlab-ci.yml`, `.github/workflows/ci.yml` : la CI, version GitLab et version GitHub
- `ci/job_ci.sh` : job Slurm du test (2 nœuds, 8 tâches)
- `ci/slurm_poll.sh` : soumission, suivi avec `sacct`, code retour
- `ci/spack_install.sh` : installe l'env Spack sur un nœud de calcul
- `spack/spack.yaml`, `spack/spack.lock` : l'environnement OpenMPI + CMake

## Lancer

En local :

```bash
cmake -S . -B build -DMPIEXEC_PREFLAGS="--oversubscribe"
cmake --build build && cd build && ctest --output-on-failure
```

Sur ROMEO, depuis le login (changer `--account` dans `ci/*.sh`) :

```bash
romeo_load_x64cpu_env
sbatch --wait ci/spack_install.sh
ci/slurm_poll.sh ci/job_ci.sh
```

En CI, le job `test_hpc` fait la même chose sur un runner auto-hébergé installé sur romeo1, avec le label `hpc-login`. Comme le dépôt est public, le runner n'est pas laissé enregistré : pour relancer `test_hpc`, il faut le réenregistrer avec un jeton (Settings > Actions > Runners) puis le démarrer :

```bash
cd ~/actions-runner-tp6
./config.sh --url https://github.com/wolf75222/mpi-devops-tp6 --labels hpc-login
setsid nohup ./run.sh > runner.log 2>&1 &
```
