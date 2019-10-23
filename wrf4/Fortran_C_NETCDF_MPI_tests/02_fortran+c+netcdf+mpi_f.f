        PROGRAM foo
        INCLUDE 'mpif.h'

        !  For netcdf

        INCLUDE 'netcdf.inc'
        INTEGER ncid , status

        !  For Fortran/C

        INTEGER :: ii
        REAL    :: xx

        !  Fortran/C

        ii = 1
        xx = 2
        CALL c_test ( xx , ii )

        !  MPI test

        CALL mpi_init ( status )

        !  netCDF test

        status = nf_open ( 'foo.nc' , 0 , ncid )
        PRINT *,'status = ',status

        !  Close down MPI

        CALL mpi_finalize ( status )
        PRINT *,'SUCCESS test 2 fortran + c + netcdf + mpi'

        END PROGRAM

