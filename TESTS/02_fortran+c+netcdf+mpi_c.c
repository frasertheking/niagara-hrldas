#ifndef CRAY
# ifdef NOUNDERSCORE
#      define C_TEST c_test
# else
#   ifdef F2CSTYLE
#      define C_TEST c_test__
#   else
#      define C_TEST c_test_
#   endif
# endif
#endif
#include <stdio.h>

int C_TEST ( float *xx, int *ii )

{
 printf("   C function called by Fortran\n" ) ;
 printf("   Values are xx = %5.2f and ii = %d \n", *xx, *ii ) ;
 return(0) ;
}

