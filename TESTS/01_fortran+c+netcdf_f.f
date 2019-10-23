        PROGRAM foo

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

        !  netCDF test

        status = nf_open ( 'foo.nc' , 0 , ncid )
        PRINT *,'SUCCESS test 1 fortran + c + netcdf'

        END PROGRAM

