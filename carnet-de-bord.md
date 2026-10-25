# Carnet de bord, Cours 6 : DevOps pour le HPC (séance inversée)

M2 CHPS, CHPS0902.

J'ai fait les missions 3 et 4 sur ROMEO 2025 (URCA), l'alternative au cluster GCP prévue par l'énoncé. Compte Slurm `r260105`, partition `instant`, contrainte `x64cpu` (nœuds AMD EPYC 9654).

Dépôt : https://github.com/wolf75222/mpi-devops-tp6 (public), commit évalué tagué `seance-inversee`.

Contenu du dépôt :

| Fichier | Rôle |
|---|---|
| `src/bcast_test.c` | test MPI : le rang 0 diffuse 1024 entiers, chaque rang vérifie, `MPI_Allreduce` agrège. Code retour ≠ 0 si un rang échoue |
| `CMakeLists.txt` | build + test CTest (`mpiexec -n 4`, réussi si la sortie contient `PASSED`) |
| `.gitlab-ci.yml` | stages `lint`, `build`, `test`, `package`, `test_hpc` |
| `.github/workflows/ci.yml` | la même chose pour GitHub Actions, plus le job `test_hpc` qui tourne sur ROMEO |
| `ci/job_ci.sh` | job Slurm de CI (2 nœuds, 8 tâches, affiche `SUCCESS`) |
| `ci/slurm_poll.sh` | `sbatch --parsable`, suivi avec `sacct`, récupération du log, code retour |
| `ci/spack_install.sh` | installe l'environnement Spack sur un nœud de calcul |
| `spack/spack.yaml`, `spack/spack.lock` | environnement OpenMPI + CMake |

---

## Mission 1 : pipeline minimal

### Ce que j'ai fait

Un petit code C+MPI qui teste `MPI_Bcast`, un `CMakeLists.txt` et un test CTest.

Dans `.gitlab-ci.yml`, le job `build` tourne dans `gcc:13-bookworm` (CMake et OpenMPI installés en `before_script`) et garde `build/` en artefact. Le job `test` a `needs: [build]`, il lance `ctest` puis `mpirun -np 4 --allow-run-as-root --oversubscribe`.

Pour que `ctest` marche aussi en root dans le conteneur, je passe `--allow-run-as-root;--oversubscribe` à CMake via `-DMPIEXEC_PREFLAGS`.

### Preuves

Run GitHub Actions (`.github/workflows/ci.yml`, même contenu que le `.gitlab-ci.yml`), push sur `main`, commit `f546808` :

```
build: success (30s)          # conteneur gcc:13-bookworm, artefact build/ uploadé
test:  success (42s)          # needs: build -> download-artifact
  1/1 Test #1: bcast_np4 ........................   Passed    0.33 sec
  100% tests passed, 0 tests failed out of 1
  rank 0/4 on ee5b384f5380: ok          <- les 4 rangs sur le même conteneur
  MPI_Bcast test with 4 ranks: PASSED
```

### Erreurs rencontrées

Le premier run Actions a planté dès l'`apt-get install` du job `build` :

```
Setting up gfortran (4:12.2.0-3) ...
update-alternatives: error: alternative path /usr/bin/gfortran doesn't exist
dpkg: error processing package gfortran (--configure)
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

`libopenmpi-dev` recommande `libcoarrays-openmpi-dev`, qui tire le `gfortran` de Debian. Son script de post-install échoue parce que l'image `gcc:13` a son propre GCC dans `/usr/local`. Corrigé avec `apt-get install --no-install-recommends`, dans les deux fichiers de CI. Pendant ce run, `lint`, `test` et `package` sont passés en `skipped` : le job en échec bloque bien la suite.

Autre détail : l'artefact `build/` ne contient pas le runtime OpenMPI, donc le job `test` refait l'`apt-get install`. Une image avec OpenMPI déjà installé éviterait ça. Et `upload-artifact` perd le bit exécutable, d'où le `chmod +x` dans `test`.

### Questions de cadrage

**Deux jobs d'un même stage échouent : le pipeline continue-t-il ?**

Non. Les jobs du stage en cours tournent en parallèle et vont au bout, mais les stages suivants passent en `skipped` et le pipeline finit en `failed`. Tant mieux : tester ou packager un binaire qui n'a pas compilé ne sert à rien, et sur un cluster ça peut coûter des heures de calcul. On peut changer ça au cas par cas avec `allow_failure: true` (job non bloquant) ou `when: always` / `on_failure` (nettoyage, rapport). Avec `needs:`, un job ne dépend plus de tout le stage précédent, seulement des jobs qu'il liste.

**`mpirun` dans le conteneur CI ou sur un cluster ?**

Dans le conteneur, les 4 rangs tournent sur un seul hôte avec souvent 2 vCPU (d'où `--oversubscribe`), en root (d'où `--allow-run-as-root`), et ils communiquent par mémoire partagée (`vader/sm`). Ça vérifie que le code est correct, pas plus. Sur ROMEO, `srun` répartit les rangs sur plusieurs nœuds (`romeo-c[023,040]` dans mon test) : là on teste aussi le réseau, PMIx/Slurm, le placement, l'OpenMPI installé sur le site et les performances. Un bug qui n'apparaît qu'entre nœuds (deadlock selon la taille des messages, ordre des rangs, structures mal sérialisées) passe le CI en conteneur sans problème.

**Pourquoi le test échoue sans `needs:` alors que le build a réussi ?**

Chaque job démarre dans un conteneur neuf avec un clone propre du dépôt, donc `build/` n'existe que s'il arrive par un artefact. Sans `needs:`, ça dépend de la syntaxe : soit le job hérite des artefacts de tout le stage précédent (comportement historique), soit, avec `needs: []` ou un DAG mal écrit, il n'en reçoit aucun. Dans ce cas `ctest` répond « No tests were found » ou `./bcast_test: not found`. Avec `needs: [build]`, on récupère l'artefact de ce job précis, et `test` démarre dès que `build` est fini.

### Bilan

- Ça marche : code, CMake/CTest, pipeline build puis test (artefacts + `needs`) vert sur GitHub Actions.
- Pas fait : faire tourner la version GitLab sur un vrai runner GitLab.
- À refaire, j'utiliserais une image CI avec OpenMPI préinstallé (ou un `cache:` apt) plutôt que de réinstaller dans chaque job.

---

## Mission 2 : déclencheurs, règles et secrets

### Ce que j'ai fait

- `lint` (cppcheck), seulement sur les merge requests : `rules: - if: $CI_PIPELINE_SOURCE == "merge_request_event"`.
- `package` (tarball + `sha256sum`), seulement sur les tags `vX.Y.Z` : `rules: - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'`.
- `registry_login` : `echo "$REGISTRY_TOKEN" | docker login --password-stdin`. `REGISTRY_TOKEN` est une fausse valeur déclarée dans *Settings > CI/CD > Variables* (Masked + Protected), pas dans le YAML.

### Preuves

Un run GitHub Actions par événement :

| Événement | build | test | lint | package | registry_login |
|---|---|---|---|---|---|
| push `main` | ✅ | ✅ | skipped | skipped | ✅ |
| tag `v1.0.0` | ✅ | ✅ | skipped | ✅ | skipped |
| pull request `lint-demo` vers `main` | ✅ | ✅ | ✅ | skipped | skipped |

`package` sur le tag `v1.0.0` :
```
731111c8232392a1a5e53e14a13018dcb50fc9f1ce779276123f512047606fa8  mpi-devops-1.0.0.tar.gz
```

`lint` sur la PR : `Checking src/bcast_test.c ...`, aucune alerte, code retour 0.

`registry_login` : le secret apparaît masqué (`***`) dans le log :
```
Run echo "***" | docker login -u "wolf75222" --password-stdin ghcr.io || echo "login simulé (fausse valeur)"
Error response from daemon: Get "https://ghcr.io/v2/": denied: denied
login simulé (fausse valeur)
```


### Erreurs rencontrées

`cppcheck` n'existe pas dans le Spack de ROMEO (`No package matches the query: cppcheck`). Le lint reste donc dans le conteneur CI, avec `apt-get install cppcheck`.

### Questions de cadrage

**`rules:` ou `only:/except:` ?**

`rules:` aujourd'hui. On peut y combiner conditions sur les variables, `changes:` et `exists:`, et fixer `when:` / `allow_failure:` règle par règle. `only:/except:` est déprécié mais toujours accepté : on le croise dans les vieux dépôts et les templates hérités, il faut savoir le lire pour le migrer. On ne peut pas mélanger les deux dans un même job.

**Que devient une variable « Protected » sur une branche non protégée ?**

Elle n'est pas injectée, la variable est vide. Sinon, n'importe qui pouvant pousser une branche (ou ouvrir une MR depuis un fork) pourrait modifier le `.gitlab-ci.yml` pour faire un `echo $TOKEN | curl …` et récupérer le secret. Seuls les branches et tags protégés, où le push est restreint et passe par une revue, voient les secrets de déploiement. Dans `registry_login`, je teste `test -n "$REGISTRY_TOKEN"` pour échouer clairement plutôt que tenter un login vide.

**Pourquoi ne jamais mettre un secret dans `.gitlab-ci.yml`, même temporairement ?**

Parce qu'il reste dans l'historique Git, et donc dans tous les clones, forks et miroirs, même si un commit suivant le retire. Il faut alors le révoquer : réécrire l'historique ne suffit pas. Il est aussi visible en clair dans l'éditeur de pipeline, dans les logs si la commande est affichée, et dans `ps` s'il est passé en argument (`-p motdepasse`). Avec `--password-stdin`, il ne passe ni par la ligne de commande ni par l'historique du shell, et une variable masquée s'affiche `[MASKED]` dans les logs.

### Bilan

- Ça marche : `lint` seulement sur PR, `package` seulement sur tag `vX.Y.Z`, secret masqué passé par `--password-stdin`.
- Limite : GitHub n'a pas d'équivalent direct de « Protected » pour les secrets, il faudrait passer par des *environments* avec règles de protection.
- À refaire, j'ajouterais un job `publish` vers les GitLab Releases à partir des artefacts de `package`.

---

## Mission 3 : du CI vers Slurm (ROMEO)

### Adaptation à ROMEO

ROMEO n'a pas de partition `debug`. `sinfo -s` donne `instant` (1 h max), `short` (24 h) et `long` (30 jours). J'ai pris `instant`, la plus courte et la plus prioritaire.

Quatre options sont obligatoires sur ROMEO : `--account`, `--time`, `--mem` et `--constraint=x64cpu`.

Il n'y a pas de Lmod : on charge l'environnement avec `romeo_load_x64cpu_env`, puis Spack. `job_ci.sh` active l'environnement Spack du dépôt (`spack env activate -d spack`), installé juste avant par `ci/spack_install.sh`.

L'énoncé dit que `job_ci.sh` « exécute le binaire MPI ». Le mien compile aussi le code, dans le job, sur le nœud de calcul. Le binaire du stage `build` ne peut pas servir ici : il sort d'un conteneur Debian avec l'OpenMPI 4.1.4 de Debian, pas celui de ROMEO. Et le CM dit que le runner du login orchestre mais ne calcule pas, donc je ne compile pas sur le login non plus. La compilation prend quelques secondes.

Un runner hébergé par GitHub ne peut pas joindre ROMEO. J'ai pris la solution du runner installé sur le nœud de login : un runner GitHub Actions auto-hébergé (version 2.338.1, archive officielle vérifiée par sha256) dans `~/actions-runner-tp6` sur romeo1, sous mon compte, avec le label `hpc-login`. C'est l'équivalent de `tags: [hpc-login]` côté GitLab. Il n'a besoin que d'une connexion sortante vers GitHub, rien à ouvrir côté ROMEO.

```
$ ./config.sh --unattended --url https://github.com/wolf75222/mpi-devops-tp6 \
              --name romeo1-hpc-login --labels hpc-login --work _work
$ setsid nohup ./run.sh > runner.log 2>&1 &
√ Connected to GitHub
Listening for Jobs
```

Le jeton d'enregistrement est passé par la variable `ACTIONS_RUNNER_INPUT_TOKEN` et pas en argument, pour qu'il n'apparaisse pas dans `ps` sur un nœud partagé.

Le runner ne tourne pas en permanence : je l'allume pour les tests, puis je l'arrête, pour ne pas laisser un process sur un nœud de login partagé. Quand j'ai passé le dépôt en public, je l'ai aussi désenregistré (`./config.sh remove`). Sur un dépôt public, n'importe qui peut ouvrir une PR depuis un fork en modifiant le workflow pour viser `hpc-login`, et son code tournerait sur romeo1 sous mon compte. Sans runner, les jobs `test_hpc` restent en attente. Pour les relancer, il faut réenregistrer le runner avec un nouveau jeton (`./config.sh`), puis lancer `./run.sh`.

Le job `test_hpc` de `.github/workflows/ci.yml` tourne avec `runs-on: [self-hosted, hpc-login]`, sur push vers `main`, en nightly (`cron: '0 2 * * *'`) ou à la main (`workflow_dispatch`). Il fait :

1. `sbatch --wait ci/spack_install.sh` : installe l'environnement Spack depuis `spack.lock` sur un nœud de calcul (ne recompile que ce qui manque) ;
2. `ci/slurm_poll.sh ci/job_ci.sh 30` : soumission `sbatch --parsable`, polling `sacct`, log et code retour ;
3. `scancel` du job Slurm si le job CI échoue ou est annulé (`if: failure() || cancelled()`) ;
4. upload des logs Slurm en artefact avec `if: always()`.

Les étapes passent par `bash -leo pipefail {0}` : un shell de login, sinon `sbatch`, `sacct` et `romeo_load_x64cpu_env` ne sont pas disponibles.

Dans `.gitlab-ci.yml`, le job `slurm_polling` fait la même chose avec `tags: [hpc-login]`, et `slurm_wait`, lancé à la main, est la version `sbatch --wait` en trois lignes. Je n'ai pas gardé l'autre solution de l'énoncé (runner partagé qui soumet en SSH, clé en variable File) : le runner sur le login suffit, et ça évite de sortir une clé SSH de ROMEO.

### Preuves

Run GitHub Actions déclenché par un push sur `main` (commit `f546808`), job `test_hpc` vert en 1 min 37, sans rien lancer à la main :

```
Runner name: 'romeo1-hpc-login'
Machine name: 'romeo1'
Submitted batch job 784120                <- ci/spack_install.sh (sbatch --wait)
Submitted job 784121                      <- ci/job_ci.sh (slurm_poll.sh)
15:24:30 job 784121: UNKNOWN              <- sacct ne connaît pas encore le job
15:25:00 job 784121: COMPLETED
env: spack env /gpfs/home/rmdraux/actions-runner-tp6/_work/mpi-devops-tp6/mpi-devops-tp6/spack
nodes: romeo-c[023,040]
rank 0/8 on romeo-c023: ok
MPI_Bcast test with 8 ranks: PASSED
rank 4/8 on romeo-c040: ok
...
SUCCESS
final state=COMPLETED exit=0
Artifact slurm-logs has been successfully uploaded! Final size is 2779 bytes.
```

Avant de brancher le runner, j'avais mis au point les scripts à la main depuis le login. Premier job MPI réussi :

```
JobID         JobName      Partition NNodes NTasks     State ExitCode  Elapsed
768722        ci-mpi-bcast   instant      2         COMPLETED      0:0 00:00:16
768722.0      bcast_test                  2      8  COMPLETED      0:0 00:00:02
```

Et un échec provoqué exprès (`--time=00:01:00` + `sleep 90`) :

```
slurmstepd: error: *** JOB 768729 ON romeo-c023 CANCELLED AT 2026-10-21T09:17:40 DUE TO TIME LIMIT ***
final state=TIMEOUT exit=0          -> rc=1
```

Je ne m'y attendais pas : le job tué en `TIMEOUT` remonte quand même un ExitCode `0:0`. Si je n'avais regardé que l'ExitCode, il serait passé. Le script vérifie donc trois choses : l'état (`COMPLETED`), le code retour et la présence de `SUCCESS` dans le log.

### Erreurs rencontrées et résolution

1. **`cmake: error while loading shared libraries: libmd.so.0`** (job 768626, `FAILED 127:0`). Le cmake installé par ROMEO marche sur le login mais pas sur les nœuds de calcul. `readelf -d .../bin/cmake` montre `NEEDED libmd.so.0`, qui sur le login est résolue par `/lib64/libmd.so.0`. Ce cmake a visiblement été compilé sur un nœud de login et a récupéré une bibliothèque système que Spack ne suit pas. J'ai testé avec `srun` sur `romeo-c040` : 4 des 5 cmake installés plantent de la même façon. C'est l'erreur qui m'a pris le plus de temps à comprendre. J'ai fini par reconstruire cmake dans mon environnement Spack, sur un nœud de calcul (voir mission 4).
2. **`sacct` ne renvoie rien juste après `sbatch`**, le temps que le job arrive dans la base d'accounting. Le script affiche `UNKNOWN` et continue à boucler au lieu de conclure à un échec.
3. Sur une fédération de clusters, `sbatch --parsable` peut renvoyer `jobid;cluster`. Je garde seulement `${JOBID%%;*}`.
4. **Premier run du job `test_hpc` en échec** : `Error: Spec '/6huel4v' matches no installed packages` (job Slurm 784070, `FAILED`). Entre la mise au point et ce run, mon répertoire d'installation Spack (`~/.spack/userspace-installed`) avait été vidé : `patch` et le cmake que j'avais compilé n'existaient plus, et `job_ci.sh` supposait que l'environnement était déjà installé. J'ai ajouté l'étape `sbatch --wait ci/spack_install.sh` avant le test : elle installe `patch` puis l'environnement depuis `spack.lock`. Le run suivant a recompilé ce qui manquait et il est passé. La chaîne CI elle-même (soumission, polling, artefact) marchait déjà sur ce premier run.

### Polling ou `sbatch --wait` ?

`--wait` tient en une ligne et le code retour de `sbatch` est celui du job. Mais le job CI reste suspendu à cette commande toute la durée (si la connexion coupe, on perd le suivi), rien ne s'affiche pendant l'attente, et on ne voit pas si le job attend en file ou s'exécute.

Le polling demande une vingtaine de lignes, mais l'état s'affiche dans le log CI (PENDING, RUNNING), on retrouve le `JOBID` après une coupure, on distingue `TIMEOUT`, `OOM` et `NODE_FAIL`, et on peut annuler proprement.

En pratique : `--wait` pour des jobs courts sur une file peu chargée, avec un runner sur le login. Le polling pour les nightly longs, les files saturées, ou quand on passe par SSH depuis un runner partagé. Dans `test_hpc` j'utilise les deux : `--wait` pour l'installation Spack, dont je n'ai besoin que du code retour, et le polling pour le test MPI.

### Questions de cadrage

**Pourquoi un `timeout:` côté CI alors que Slurm a déjà un wall-time ?**

Le wall-time ne démarre qu'au lancement du job. Le temps passé en `PENDING` n'est limité par rien côté Slurm, et une boucle de polling peut aussi ne jamais sortir (sacct indisponible, job sorti de la base). Sans `timeout:`, le job CI bloque un runner jusqu'à la limite par défaut du projet (1 h, parfois beaucoup plus) et retarde les autres pipelines. Mon timeout de 45 min (`timeout-minutes: 45` sur GitHub, `timeout: 45m` sur GitLab) doit couvrir l'attente en file, le wall-time et une marge. Quand il expire, le job CI est annulé mais pas le job Slurm : d'où l'étape `scancel` (`after_script` sur GitLab), qui relit le `JOBID` écrit par `slurm_poll.sh` dans `.slurm_jobid`.

**Le job Slurm reste `PENDING` 20 minutes (file saturée) : que voit-on côté GitLab ?**

Le job CI est en cours (`running` sur GitLab, `in_progress` sur GitHub) : le runner attend, sans rien afficher. Avec `--wait`, le log reste vide. Mon polling affiche `hh:mm:ss job N: PENDING` toutes les 30 s. On pourrait ajouter `squeue -j $JOBID -o "%r %S"` pour avoir la raison de l'attente (`Priority`, `Resources`, `QOSMaxCpuPerUserLimit`) et l'heure de démarrage estimée. Si l'attente devient trop longue, on peut demander moins de ressources ou changer de partition.

**Le nightly échoue à 2 h du matin : trois questions avant de relancer.**

1. Dans quel état est le job Slurm, et que dit le log ? `COMPLETED` avec un ExitCode ≠ 0, ou `FAILED` sur un test qui ne passe pas : c'est le code. `NODE_FAIL`, `BOOT_FAIL`, `CANCELLED` par l'admin, `sbatch` refusé, SSH impossible ou quota GPFS plein : c'est l'infrastructure.
2. Qu'est-ce qui a changé depuis le dernier succès ? Les commits du jour (`git log`), `spack.lock`, une maintenance du cluster, une mise à jour des paquets partagés. Le cas `libmd` plus haut en est un exemple : l'environnement avait changé, pas le code.
3. Est-ce que ça se reproduit ? Même commit, autre nœud, ou relance à la main. Un échec intermittent fait penser à l'infra ou à une race condition MPI, un échec systématique plutôt au code.

On relance un échec d'infra, pas un échec de code : relancer un test rouge cacherait une régression. C'est pour ça que `retry` ne doit pas couvrir `script_failure`.

J'ai eu le cas avec mon premier run `test_hpc` raté (erreur 4 ci-dessus) : le code n'avait pas bougé, c'est l'environnement installé dans mon home qui avait disparu. La question 2 m'aurait mis sur la piste tout de suite.

### `retry: when: runner_system_failure`

`runner_system_failure` ne couvre que les pannes du runner lui-même : runner arrêté, nœud de login redémarré, process tué. Avec un runner sur le login, c'est le cas le plus probable (le mien est un process lancé à la main, un redémarrage de romeo1 le coupe), donc ça vaut le coup de le mettre.

Par contre, ça ne couvre pas les pannes côté Slurm : un `NODE_FAIL` fait échouer le script, et GitLab le voit comme un `script_failure`, comme un vrai bug. Pour les séparer, `slurm_poll.sh` sort avec 0 en cas de succès, 1 pour un échec du code et 2 pour un échec d'infrastructure (`NODE_FAIL`, `BOOT_FAIL`, `PREEMPTED`, `sbatch` refusé). Dans `.gitlab-ci.yml`, `slurm_polling` a donc `retry: max: 1`, `when: [runner_system_failure, stuck_or_timeout_failure]` et `exit_codes: [2]`. Je limite à une relance : si la file est saturée, relancer 45 min de plus ne sert pas à grand-chose.

GitHub Actions n'a pas d'équivalent de `retry:` au niveau du job, il faut relancer à la main (« Re-run failed jobs ») ou passer par une action dédiée.

### Bilan

- Ça marche : quand le runner `hpc-login` de romeo1 est lancé, un push sur `main` déclenche tout seul l'installation Spack puis le test MPI sur 2 nœuds / 8 rangs, avec polling, détection des TIMEOUT, `scancel` en cas d'annulation et logs en artefact.
- Pas fait : la version GitLab (même logique, `tags: [hpc-login]`) n'a pas tourné, faute de projet GitLab. Le nightly est configuré mais n'a pas encore tourné, le runner étant arrêté.
- À refaire : faire tourner le runner sous un compte dédié au CI, relancé automatiquement par le système, si le centre l'autorise. Aujourd'hui il dépend d'un process que je lance à la main.

---

## Mission 4 : Spack, l'environnement comme code

### Ce que j'ai fait

```
romeo_load_x64cpu_env
spack env create -d spack
spack -e spack compiler find          # gcc@11.5.0 système détecté, ajouté en external
spack -e spack add "openmpi@4.1.7 schedulers=slurm" "cmake@3.30.9 build_type=Release %gcc@11.5.0"
spack -e spack concretize -f
sbatch --wait ci/spack_install.sh     # install sur nœud de calcul (voir erreurs)
```

L'environnement fait 49 specs. Seuls cmake@3.30.9 et son `gcc-runtime` sont compilés, avec le gcc système 11.5.0 (`%gcc@11.5.0`), en moins de 2 min sur 32 cœurs. Tout le reste (`[^]`) vient de l'installation partagée `/apps` de ROMEO grâce à `concretizer: reuse`, y compris openmpi@4.1.7 `schedulers=slurm` (`5xjwtin`). Je n'ai compilé aucun compilateur.

Pour OpenMPI, je n'ai pas réussi à mettre le `%gcc` demandé par l'énoncé (erreur 5 plus bas) : j'utilise celui du site, compilé avec aocc 5.0.0, donc `mpicc` appelle aocc.

### `spack.yaml` et `spack.lock`

`spack.yaml` contient ce que je demande : `openmpi@4.1.7 schedulers=slurm`, `cmake@3.30.9 build_type=Release %gcc@11.5.0`, les réglages du concrétiseur (`unify`, `reuse`, cmake exclu de la réutilisation) et les compilateurs externes. Quelques lignes écrites à la main, faciles à relire.

`spack.lock` contient ce que Spack a résolu : du JSON (`lockfile-version 6`, 49 `concrete_specs`) avec, pour chaque paquet du DAG, la version exacte, le compilateur, les variants (`+atomics~cuda…`, `fabrics=none`), l'architecture `linux-rhel9-zen4`, les dépendances et le hash (`openmpi 5xjwtin…`, `cmake q22mihh…`). Il est généré par `concretize` et on ne le modifie pas à la main.

### Erreurs rencontrées et résolution

1. Mettre `cmake/py755eb` ou `cmake@3.30.5 %aocc@5.0.0` dans `specs` ne marche pas : soit c'est ignoré, soit `Cannot satisfy 'cmake@3.30.5'`. Toutes les versions installées par ROMEO ne sont pas dans les recettes de Spack 1.0.1 (`cmake@3.31.8` non plus), et un paquet installé avec l'ancien modèle de compilateur ne peut pas servir de racine via son hash. J'ai pris une version qui existe dans les recettes (`3.30.9`) et je l'ai construite moi-même.
2. Avec `concretizer: reuse: true`, Spack reprenait le cmake partagé, celui qui plante sur les nœuds de calcul (`libmd`, mission 3). Solution : `reuse: {roots: true, exclude: [cmake]}`, on réutilise tout sauf cmake.
3. Premier `spack install` dans un job : **`CommandNotFoundError: spack requires 'patch'`**. La commande `patch` n'existe pas sur les nœuds de calcul, encore une différence avec le login. J'ai d'abord chargé un `patch` déjà installé (`spack load /6huel4v`), puis, quand il a disparu (mission 3, erreur 4), je l'ai remplacé par `spack install patch` + `spack load patch` dans `ci/spack_install.sh`.
4. J'ai fait l'install sur un nœud de calcul et pas sur le login, pour que le binaire ne récupère pas de bibliothèques du login.
5. `openmpi@4.1.7 %gcc` : `Spack concretizer internal error … openmpi@4.1.7 %gcc is unsatisfiable`, même avec `--fresh`, `%gcc@14.2.0` ou `%c,cxx,fortran=gcc`. Le `packages.yaml` de ROMEO déclare `openmpi: buildable: false`, donc on ne peut que réutiliser un OpenMPI du site. Il en existe un compilé avec gcc 11.4.1 (`kfjcqqr`), mais il a été installé avec l'ancien modèle de compilateur et Spack 1.0.1 ne le reconnaît pas comme `%gcc`. Non résolu : OpenMPI reste celui d'aocc, et `%gcc` ne s'applique qu'à cmake.

Le run CI du 25/10 montre que le lock fait son travail : après la disparition de mon install, `spack -e spack install` a reconstruit exactement le même cmake, avec le même hash que dans `spack.lock` (à ce moment-là `ntgj5yc`, compilé avec gcc 14.2.0), et a repris le reste depuis `/apps` :

```
==> No binary for cmake-3.30.9-ntgj5ycm4xwsnsadjr4ridhyievm32gy found: installing from source
==> cmake: Successfully installed cmake-3.30.9-ntgj5ycm4xwsnsadjr4ridhyievm32gy
  Stage: 9.67s.  Bootstrap: 59.71s.  Build: 50.62s.  Install: 5.76s.  Post-install: 1.00s.  Total: 2m 7.15s
```

### Questions de cadrage

**Syntaxe `package@version%compiler+variant~variant` : spec hdf5 avec GCC, MPI et Fortran, sans C++**

```
hdf5@1.14.6 %gcc@14.2.0 +mpi +fortran ~cxx ^openmpi@4.1.7
```

Vérifiée avec `spack spec -I` sur ROMEO : `hdf5@1.14.6~cxx+fortran~hl~ipo~java~map+mpi+shared…`, à construire (`-`), avec cmake et curl réutilisés (`[^]`). `@` fixe la version, `%` le compilateur, `+` et `~` activent ou désactivent un variant, `^` contraint une dépendance (ici le MPI). Depuis Spack 1.0 on peut aussi écrire le compilateur par langage : `%c,cxx,fortran=gcc@14.2.0`.

**Pourquoi `spack.lock` suffit à reproduire l'environnement, et pas `spack.yaml` seul ?**

`spack.yaml` ne donne que des contraintes, et le concrétiseur les résout selon le contexte : version de Spack et de ses recettes (qui changent à chaque mise à jour), paquets déjà installés (`reuse`), compilateurs détectés, `packages.yaml` du site, architecture. Deux machines, ou la même machine six mois plus tard, peuvent donner des DAG différents. Ça m'est arrivé ici : sans contrainte, `cmake` s'est d'abord résolu en `3.31.8` (la version partagée), ce qui n'est plus possible maintenant que la recette n'existe plus. `spack.lock` fige le DAG exact (versions, variants, compilateurs, hash), et `spack install` à partir du lock réinstalle exactement ces specs sans repasser par le concrétiseur. Il faut quand même la même architecture cible (`zen4`) et les mêmes externals sur l'autre machine.

**À quoi sert un buildcache pour un pipeline qui réinstalle l'environnement à chaque fois ?**

Sans cache, chaque pipeline recompile tout depuis les sources : 2 min pour cmake ici, 10 à 15 min pour OpenMPI, plus d'une heure pour HDF5 ou une pile complète, à chaque run et sur chaque runner. Avec un buildcache (`spack buildcache push` vers un miroir S3, OCI ou un dossier, et `spack mirror add` côté CI), un paquet dont le hash est déjà dans le cache est téléchargé en binaire en quelques secondes, et le pipeline ne compile que ce qui a changé. Les binaires sont indexés par hash, donc même hash = même build, et on peut les signer avec GPG. Sur ROMEO, l'installation partagée `/apps` joue déjà ce rôle (`[^]` = paquet réutilisé).

### Bilan

- Ça marche : environnement OpenMPI + CMake concrétisé, installé, versionné (`spack.yaml` + `spack.lock`) et utilisé par `job_ci.sh`.
- Ça ne marche pas : réutiliser le cmake de ROMEO, qui plante sur les nœuds de calcul, et avoir un OpenMPI `%gcc` avec la config du site.
- À refaire : un buildcache perso pour ne pas recompiler cmake à chaque nouveau clone, et signaler le problème `libmd` au support ROMEO.

---

## Mission 5 : rendu

Je rends une archive zip du dossier de travail `mpi-devops/`, avec le dossier `.git` : l'historique et le tag `seance-inversee` sont dedans. Le tag pointe sur le dernier commit.

```
$ git tag
seance-inversee
v1.0.0

$ git ls-files
.github/workflows/ci.yml
.gitignore
.gitlab-ci.yml
CMakeLists.txt
README.md
carnet-de-bord.md
ci/job_ci.sh
ci/slurm_poll.sh
ci/spack_install.sh
spack/spack.lock
spack/spack.yaml
src/bcast_test.c
```

Ce que demande l'énoncé et où le trouver :

| Demandé | Dans le dépôt |
|---|---|
| code MPI et `CMakeLists.txt` | `src/bcast_test.c`, `CMakeLists.txt` |
| `.gitlab-ci.yml` et son équivalent GitHub Actions | `.gitlab-ci.yml`, `.github/workflows/ci.yml` (testé) |
| `job_ci.sh` | `ci/job_ci.sh` |
| `spack.yaml` et `spack.lock` | `spack/` |
| scripts intermédiaires | `ci/slurm_poll.sh`, `ci/spack_install.sh` |
| tag `seance-inversee` | sur le dernier commit |

Pour vérifier après dézippage :

```
$ cd mpi-devops && git log --oneline -1 seance-inversee
$ git status        # rien à commiter
```

---

## Auto-diagnostic

Ce que je sais faire maintenant :
- écrire un pipeline par stages avec artefacts et `needs`, des `rules` selon l'événement (MR, tag, schedule) et des secrets masqués/protégés ;
- soumettre un job Slurm depuis le CI et lire correctement son résultat (état + ExitCode + marqueur, puisqu'un `TIMEOUT` remonte `0:0`) ;
- utiliser un environnement Spack : ce qu'on demande (`yaml`) contre ce qui est résolu (`lock`), réutilisation de l'installation du site, exclusion d'un paquet.

Ce que je dois retravailler : je n'ai testé que GitHub Actions, il me reste à faire tourner la version GitLab (runners, variables de type File, schedules). Le runner sur le login, je le lance à la main sous mon compte et je l'arrête après usage ; pour un vrai nightly, il faudrait voir avec le centre si un runner permanent est autorisé, et le garder sur un dépôt privé. Et je n'ai pas encore monté de buildcache Spack, signé et partagé entre runners.

Ce qui m'a le plus coûté, ce sont les différences entre le nœud de login et les nœuds de calcul : `libmd.so.0` et `patch` n'existent que sur le login. En compilant et en testant uniquement sur le login, je ne les aurais jamais vues. Je retiens qu'il faut construire et tester sur les nœuds où le code tournera vraiment.

### Utilisation dans d'autres projets CHPS (exemple : imagerie médicale)

Pour un pipeline de traitement d'images (recalage et segmentation d'IRM ou de scanner, codes MPI+GPU sur `armgpu`), je mettrais une CI GitLab avec des tests unitaires en conteneur sur de petites images synthétiques, puis un nightly Slurm sur ROMEO avec un jeu de référence anonymisé. On compare les sorties numériquement (Dice, écart voxel à voxel) avec une tolérance, et on garde les logs et les cartes de différence en artefacts `when: always`.

Je versionnerais le `spack.lock` (ITK, VTK, HDF5, CUDA) avec le code, pour pouvoir recalculer un résultat publié à l'identique des mois plus tard.

Les secrets (accès PACS, entrepôts de données de santé) iraient uniquement dans des variables protégées et masquées. Les données patient ne doivent pas passer par des runners partagés : seul un runner sur l'infrastructure du centre (tag `hpc-login`) y aurait accès.
