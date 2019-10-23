










program Noah_hrldas_driver
! this is the main program to drive HRLDAS-Noah, HRLDAS-NoahMP, and other Land models.

! this is used to drive NoahMP
   use module_noahmp_hrldas_driver, only: land_driver_ini, land_driver_exe

   implicit none
   integer :: ITIME, NTIME

   call land_driver_ini(NTIME)
   
   do ITIME = 0, NTIME
       call land_driver_exe(ITIME)
   end do

END 

