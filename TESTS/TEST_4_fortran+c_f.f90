PROGRAM foo
   INTEGER :: ii
   REAL    :: xx

   ii = 1
   xx = 2

   CALL c_test ( xx , ii ) 

   print *,'SUCCESS test 4 fortran calling c'

END PROGRAM foo

