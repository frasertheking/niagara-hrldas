! free form Fortran only
PROGRAM foo

   USE, INTRINSIC :: ISO_C_BINDING, ONLY: c_char, c_ptr, c_int32_t, &
                            c_int64_t, c_loc, &
                            c_null_char, c_null_ptr, c_f_pointer

   TYPE, BIND(C) :: r_info
      INTEGER(C_INT64_T)                         :: offset
      INTEGER(C_INT64_T)                         :: data_offset
      INTEGER(C_INT32_T)                         :: data_count
      INTEGER(C_INT32_T)                         :: data_type
      CHARACTER(KIND=C_CHAR), DIMENSION(10) :: name
      CHARACTER(KIND=C_CHAR), DIMENSION(10) :: date
   END TYPE r_info

   TYPE bunch_of_stuff 
      INTEGER,POINTER,DIMENSION(:) :: i
      REAL   ,POINTER,DIMENSION(:) :: x
      LOGICAL,POINTER,DIMENSION(:) :: l
   END TYPE bunch_of_stuff

   TYPE outer_wrapper
      TYPE(bunch_of_stuff), ALLOCATABLE, DIMENSION(:) :: ddt_things
   END TYPE outer_wrapper

   TYPE(outer_wrapper), DIMENSION(15) :: combo

   ALLOCATE(combo(1)%ddt_things(10))
   ALLOCATE(combo(2)%ddt_things(10))
   ALLOCATE(combo(3)%ddt_things(10))
   PRINT *,'Assume Fortran 2003: has FLUSH, ALLOCATABLE derived type, and ISO C Binding'
   PRINT *,'SUCCESS test 2 fortran only free format'
   FLUSH (UNIT=6)
END PROGRAM foo
