/* Le rang 0 diffuse un tableau, chaque rang le vérifie, MPI_Allreduce
 * rassemble les résultats. Retourne 0 si tous les rangs l'ont bien reçu. */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

#define N 1024  /* nombre d'entiers diffusés */

int main(int argc, char **argv)
{
    int rank, size, i, ok = 1, all_ok = 0;
    int buf[N];
    char host[MPI_MAX_PROCESSOR_NAME];
    int len;

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    MPI_Get_processor_name(host, &len);

    for (i = 0; i < N; i++)
        buf[i] = (rank == 0) ? 3 * i + 7 : -1;

    MPI_Bcast(buf, N, MPI_INT, 0, MPI_COMM_WORLD);

    for (i = 0; i < N; i++)
        if (buf[i] != 3 * i + 7) { ok = 0; break; }

    MPI_Allreduce(&ok, &all_ok, 1, MPI_INT, MPI_LAND, MPI_COMM_WORLD);

    printf("rank %d/%d on %s: %s\n", rank, size, host, ok ? "ok" : "FAIL");
    if (rank == 0)
        printf("MPI_Bcast test with %d ranks: %s\n", size, all_ok ? "PASSED" : "FAILED");

    MPI_Finalize();
    return all_ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
