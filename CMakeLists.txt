cmake_minimum_required(VERSION 3.20)
project(mpi_devops C)

find_package(MPI REQUIRED COMPONENTS C)

add_executable(bcast_test src/bcast_test.c)
target_link_libraries(bcast_test PRIVATE MPI::MPI_C)

# MPIEXEC_PREFLAGS : --allow-run-as-root;--oversubscribe dans le conteneur CI
enable_testing()
add_test(NAME bcast_np4
         COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 4 ${MPIEXEC_PREFLAGS}
                 $<TARGET_FILE:bcast_test> ${MPIEXEC_POSTFLAGS})
set_tests_properties(bcast_np4 PROPERTIES PASS_REGULAR_EXPRESSION "PASSED" TIMEOUT 60)
