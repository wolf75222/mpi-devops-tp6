#!/usr/bin/env bash
# Soumet un job Slurm, suit son état avec sacct, affiche le log.
# Usage : ci/slurm_poll.sh <script> [intervalle_s]
# Sortie : 0 succès, 1 échec du code, 2 échec d'infra (à relancer).
set -uo pipefail

SCRIPT=${1:-ci/job_ci.sh}
INTERVAL=${2:-15}

JOBID=$(sbatch --parsable "$SCRIPT") || { echo "sbatch a échoué"; exit 2; }
JOBID=${JOBID%%;*}            # --parsable peut renvoyer "jobid;cluster"
echo "Submitted job $JOBID"
echo "$JOBID" > .slurm_jobid  # pour le scancel si le job CI est annulé

while true; do
    STATE=$(sacct -j "$JOBID" -X -n -o State | head -1 | tr -d ' ')
    echo "$(date +%T) job $JOBID: ${STATE:-UNKNOWN}"
    case "$STATE" in
        COMPLETED|FAILED|TIMEOUT|CANCELLED*|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|BOOT_FAIL) break ;;
    esac
    sleep "$INTERVAL"
done

LOG=ci-$JOBID.out
[ -f "$LOG" ] && cat "$LOG"
EXIT=$(sacct -j "$JOBID" -X -n -o ExitCode | head -1 | tr -d ' ' | cut -d: -f1)
echo "final state=$STATE exit=$EXIT"

case "$STATE" in
    NODE_FAIL|BOOT_FAIL|PREEMPTED) echo "échec d'infra ($STATE)"; exit 2 ;;
esac
# un TIMEOUT sort avec 0:0, donc on vérifie aussi l'état et SUCCESS
[ "$STATE" = COMPLETED ] && [ "$EXIT" -eq 0 ] && grep -q '^SUCCESS' "$LOG"
