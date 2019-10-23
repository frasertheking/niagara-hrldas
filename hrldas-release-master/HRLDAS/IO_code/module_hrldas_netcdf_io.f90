










module module_hrldas_netcdf_io
  use module_date_utilities
  use netcdf


  implicit none

  logical, parameter :: FATAL = .TRUE.
  logical, parameter :: NOT_FATAL = .FALSE.

  type inputstruct
     character(len=19)             :: read_date
     real, pointer, dimension(:,:) :: t
     real, pointer, dimension(:,:) :: q
     real, pointer, dimension(:,:) :: u
     real, pointer, dimension(:,:) :: v
     real, pointer, dimension(:,:) :: p
     real, pointer, dimension(:,:) :: lw
     real, pointer, dimension(:,:) :: sw
     real, pointer, dimension(:,:) :: pcp
     real, pointer, dimension(:,:) :: snow
     real, pointer, dimension(:,:) :: vegfra
     real, pointer, dimension(:,:) :: lai
  end type inputstruct

  character(len=256), private :: restart_filename_remember
  integer, private :: iswater_remember
  integer, private :: xstartpar_remember
  integer, private, allocatable, dimension(:,:) :: vegtyp_remember
  integer, private :: ncid_remember
  integer, private :: output_count_remember = 0
  logical, private :: define_mode_remember
  integer, private :: dimid_ix_remember
  integer, private :: dimid_jx_remember
  integer, private :: dimid_times_remember
  integer, private :: dimid_layers_remember
  integer, private :: dimid_snow_layers_remember

  interface prepare_output_file
     module procedure prepare_output_file_seq
  end interface

  interface prepare_restart_file
     module procedure prepare_restart_file_seq
  end interface


  interface add_to_restart
     module procedure add_to_restart_2d_float, add_to_restart_2d_integer, add_to_restart_3d
  end interface

  interface get_from_restart
     module procedure get_from_restart_2d_float, get_from_restart_2d_integer, get_from_restart_3d, get_from_restart_att
  end interface

  interface add_to_output
     module procedure add_to_output_2d_float, add_to_output_2d_integer, add_to_output_3d
  end interface

contains

!-------------------------------------------------------------------------------------------------------
!-------------------------------------------------------------------------------------------------------

  subroutine check_outdir(rank, outdir)
    implicit none

    ! Check that output directory OUTDIR exists and is writable, by
    ! trying to open a test file in that directory.  Include a random
    ! number in the test file name, to greatly reduce the chance of 
    ! collision with existing file names.  This assumes that the 
    ! intrinsic random_seed routine, called without argument, will seed 
    ! the random number generator based on something like system time 
    ! or hardware noise.

    integer,          intent(in) :: rank
    character(len=*), intent(in) :: outdir

    real                         :: xrand
    character(len=256)           :: testfile
    integer                      :: ierr

    if (rank == 0) then
       call random_seed()
       call random_number(xrand)
       write(testfile, '(A,"/scratch.",I4.4,".",I6.6,".scratch")') trim(outdir), rank, int(xrand*1.E6)
       open(unit=30, file=trim(testfile), status='unknown', iostat=ierr)
       if (ierr /= 0) then
          write(*, '(/)')
          write(*, '(" ***** Namelist error: ******************************************************")')
          write(*, '(" ***** ")')
          write(*, '(" ***** We cannot write a file to the directory specified in namelist option OUTDIR.")')
          write(*, '(" ***** Check namelist option OUTDIR (currently set to ''", A, "'')")') trim(outdir)
          write(*, '(" *****       Check that the directory exists, is a directory, and is writable.")')
          write(*, '(/)')
          stop "OUTDIR Problem"
       endif
       close(unit=30, iostat=ierr, status='delete')
       if (ierr /= 0) then
          print*, "TESTFILE = " // trim(testfile) // '"'
          stop "Much confusion.  Problem closing test file."
       endif
    endif
  end subroutine check_outdir

!-------------------------------------------------------------------------------------------------------
!-------------------------------------------------------------------------------------------------------

  subroutine find_restart_file(rank, restart_filename_requested, startdate, khour, olddate, restart_flnm)
    implicit none
    !
    ! If the user has requested the latest restart file, find the latest restart file.
    ! If the user has requested a specific restart file, check that the file exists.
    !
    ! Return the restart file name in string RESTART_FLNM.
    ! Update the OLDDATE string (in case the latest restart file was requested).
    !
    integer,            intent(in)    :: rank
    character(len=*),   intent(in)    :: restart_filename_requested
    character(len=19),  intent(in)    :: startdate
    integer,            intent(in)    :: khour
    character(len=19),  intent(in)    :: olddate
    character(len=256), intent(out)   :: restart_flnm
    character(len=19)                 :: locdate
    integer                           :: ribeg
    integer                           :: riend
    logical                           :: lexist


    ribeg = index(restart_filename_requested, "<LATEST>")-1

    if ( ribeg > 0 ) then

       riend = ribeg + 9
       ! Find the latest RESTART file
       call geth_newdate(locdate(1:13), olddate(1:13), khour+24)
       RLOOP : do
          restart_flnm = restart_filename_requested(1:ribeg) //                 &
               locdate(1:4)//locdate(6:7)//locdate(9:10)//locdate(12:13) //     &
               restart_filename_requested(riend:)
          inquire (file=trim(restart_flnm), exist=lexist)
          if ( .not. lexist ) then
             call geth_newdate(locdate(1:13), locdate(1:13), -1)
             if (locdate(1:13) < startdate(1:13) ) then
                write(*, *)
                write(*, '(" ***** RESTART error: **************************************************")')
                write(*, '(" ***** ")')
                write(*, '(" *****       You have requested to restart from the latest restart file,")')
                write(*, '(" *****       but no restart file was found.")')
                write(*, '(" ***** ")')
                write(*, *)
                stop " ***** ERROR EXIT:  Cannot find a restart file"
             endif
          else
             exit RLOOP
          endif
       enddo RLOOP

    else

       restart_flnm = restart_filename_requested
       inquire (file=trim(restart_flnm), exist=lexist)
       if ( .not. lexist ) then
          write(*, *)
          write(*, '(" ***** RESTART error: **************************************************")')
          write(*, '(" ***** ")')
          write(*, '(" *****       You have requested to restart from a file that cannot be found.")')
          write(*, '(" *****       Specified restart file = ''", A, "''")') trim(restart_flnm)
          write(*, '(" ***** ")')
          write(*, *)
          stop " ***** ERROR EXIT:  Cannot find restart file"
       endif

    endif

    if (rank == 0) then
       write(*, '("Found restart file:  ''", A, "''")') trim(restart_flnm)
    endif

  end subroutine find_restart_file

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine read_dim(wrfinput_flnm, ix, jx)
       implicit none
       character(len=*),   intent(in)    :: wrfinput_flnm
       integer,            intent(out)   :: ix, jx    ! dimensions 
       integer  :: ncid, dimid, ierr
       ierr = nf90_open(wrfinput_flnm, NF90_NOWRITE, ncid)

       ierr = nf90_inq_dimid(ncid, "west_east", dimid)
       call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension 'west_east'")

       ierr = nf90_inquire_dimension(ncid, dimid, len=ix)
       call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension length for 'west_east'")
   
       ierr = nf90_inq_dimid(ncid, "south_north", dimid)
       call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension 'south_north'")
   
       ierr = nf90_inquire_dimension(ncid, dimid, len=jx)
       call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension length for 'south_north'")

  end subroutine read_dim

  subroutine read_hrldas_hdrinfo(wrfinput_flnm, ix, jx, &
       xstart, xend, ystart, yend,                      &
       iswater, islake, isurban, isice, llanduse, dx, dy, truelat1, truelat2, cen_lon, lat1, lon1, &
       igrid, mapproj)
    ! Return the dimensions of the grid and some map information.
    implicit none
    character(len=*),   intent(in)    :: wrfinput_flnm
    integer,            intent(out)   :: mapproj
    integer,            intent(out)   :: igrid
    integer,            intent(out)   :: ix, jx    ! dimensions
    integer,            intent(in)    :: xstart, ystart ! Subwindow definition
    integer,            intent(inout) :: xend, yend     ! Subwindow definition
    integer,            intent(out)   :: iswater   ! vegetation category corresponding to water bodies
    integer,            intent(out)   :: islake    ! vegetation category corresponding to lakes
    integer,            intent(out)   :: isurban   ! vegetation category corresponding to urban areas
    integer,            intent(out)   :: isice     ! vegetation category corresponding to ice areas
    character(len=256), intent(out)   :: llanduse  ! Landuse dataset (USGS or MODI)
    real,               intent(out)   :: dx
    real,               intent(out)   :: dy
    real,               intent(out)   :: truelat1
    real,               intent(out)   :: truelat2
    real,               intent(out)   :: cen_lon
    real,               intent(out)   :: lat1
    real,               intent(out)   :: lon1
    integer :: ncid, dimid, varid, ierr
    real, allocatable, dimension(:,:) :: dum2d
    character(len=256) :: units
    integer :: i
    integer :: rank

    rank = 0


    ! Open the NetCDF file.
    if (rank == 0) write(*,'("wrfinput_flnm: ''", A, "''")') trim(wrfinput_flnm)

!KWM#ifdef _PARALLEL_
!KWM    ierr = nf90_open_par(wrfinput_flnm, NF90_NOWRITE, MPI_COMM_WORLD, MPI_INFO_NULL, ncid)
!KWM#else
    ierr = nf90_open(wrfinput_flnm, NF90_NOWRITE, ncid)
!KWM#endif
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO: Problem opening wrfinput file: "//trim(wrfinput_flnm))

    ierr = nf90_inq_dimid(ncid, "west_east", dimid)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension 'west_east'")

    ierr = nf90_inquire_dimension(ncid, dimid, len=ix)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension length for 'west_east'")

    ierr = nf90_inq_dimid(ncid, "south_north", dimid)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension 'south_north'")

    ierr = nf90_inquire_dimension(ncid, dimid, len=jx)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding dimension length for 'south_north'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "DX", dx)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'DX'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "DY", dy)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'DY'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "TRUELAT1", truelat1)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'TRUELAT1'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "TRUELAT2", truelat2)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'TRUELAT2'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "STAND_LON", cen_lon)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'STAND_LON'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "MAP_PROJ", mapproj)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'MAP_PROJ'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "GRID_ID", igrid)
    if (ierr /= 0) then
       ierr = nf90_get_att(ncid, NF90_GLOBAL, "grid_id", igrid)
       call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'GRID_ID' or 'grid_id'")
    endif

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "ISWATER", iswater)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'ISWATER'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "ISLAKE", islake)
    if(ierr /= 0) then
      write(*,*) "Problems finding global attribute: ISLAKE; setting to -1"
      islake = -1
    end if

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "ISURBAN", isurban)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'ISURBAN'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "ISICE", isice)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'ISICE'")

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "MMINLU", llanduse)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems finding global attribute 'MMINLU'")
    
    ! IBM XLF seems to need something like this:
    do i = 1, 256
       if (ichar(llanduse(i:i)) == 0) llanduse(i:i) = " "
    enddo

    if (xend == 0) then
       xend = ix
    endif
    if (yend == 0) then
       yend = jx
    endif

!
! This section is for reading the information from the wrfinput file
!

    ! We only need to read the one starting point.
    allocate(dum2d(xstart:xstart,ystart:ystart))
    call get_2d_netcdf("XLAT", ncid, dum2d,  units, xstart, xstart, ystart, ystart, FATAL, ierr)
    lat1 = dum2d(xstart,ystart)

    call get_2d_netcdf("XLONG", ncid, dum2d,  units, xstart, xstart, ystart, ystart, FATAL, ierr)
    lon1 = dum2d(xstart,ystart)
    deallocate (dum2d)



    ierr = nf90_close(ncid)
    call error_handler(ierr, failure="READ_HRLDAS_HDRINFO:  Problems closing NetCDF file.")

  end subroutine read_hrldas_hdrinfo

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine readland_hrldas(wrfinput_flnm,                            &
       xstart, xend,                                                   &
       ystart, yend,                                                   &
       iswater, islake, vegtyp, soltyp, terrain, tbot_2d, latitude, longitude,xland,seaice,msftx,msfty)
    implicit none
    character(len=*),          intent(in)  :: wrfinput_flnm
    integer,                   intent(in)  :: xstart, xend, ystart, yend
    integer,                   intent(in)  :: iswater
    integer,                   intent(in)  :: islake
    integer, dimension(xstart:xend,ystart:yend), intent(out) :: vegtyp, soltyp
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: terrain
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: tbot_2d
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: latitude
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: longitude
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: xland
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: seaice
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: msftx
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: msfty

    character(len=256) :: units
    integer :: ierr
    integer :: ncid
    real, dimension(xstart:xend,ystart:yend) :: xdum
    integer :: rank

    rank = 0


    ! Open the NetCDF file.
    if (rank == 0) write(*,'("wrfinput_flnm: ''", A, "''")') trim(wrfinput_flnm)
    ierr = nf90_open(wrfinput_flnm, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("READLAND_HRLDAS:  Problem opening wrfinput file: ''", A, "''")') trim(wrfinput_flnm)
       stop
    endif

    ! Get Latitude (lat)
    call get_2d_netcdf("XLAT", ncid, latitude,  units, xstart, xend, ystart, yend, FATAL, ierr)
    ! print*, 'latitude(xstart,ystart) = ', latitude(xstart,ystart)

    ! Get Longitude (lon)
    call get_2d_netcdf("XLONG", ncid, longitude, units, xstart, xend, ystart, yend, FATAL, ierr)
    ! print*, 'longitude(xstart,ystart) = ', longitude(xstart,ystart)

    ! Get land mask (xland)
    call get_2d_netcdf("XLAND", ncid, xland, units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
    ! print*, 'xland(xstart,ystart) = ', xland(xstart,ystart)

    ! Get seaice (seaice)
    call get_2d_netcdf("SEAICE", ncid, seaice, units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
    ! print*, 'seaice(xstart,ystart) = ', seaice(xstart,ystart)

    ! Get Terrain (avg)
    call get_2d_netcdf("HGT", ncid, terrain,   units, xstart, xend, ystart, yend, FATAL, ierr)
    ! print*, 'terrain(xstart,ystart) = ', terrain(xstart,ystart)

    ! Get Deep layer temperature (TMN)
    call get_2d_netcdf("TMN", ncid, tbot_2d,   units, xstart, xend, ystart, yend, FATAL, ierr)
    ! print*, 'terrain(xstart,ystart) = ', terrain(xstart,ystart)

    ! Get Map Factors (MAPFAC_MX)
    call get_2d_netcdf("MAPFAC_MX", ncid, msftx,   units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
    ! print*, 'msftx(xstart,ystart) = ', msftx(xstart,ystart)
    if (ierr /= 0) print*, 'Did not find MAPFAC_MX, only needed for iopt_run=5'

    ! Get Map Factors (MAPFAC_MY)
    call get_2d_netcdf("MAPFAC_MY", ncid, msfty,   units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
    ! print*, 'msfty(xstart,ystart) = ', msfty(xstart,ystart)
    if (ierr /= 0) print*, 'Did not find MAPFAC_MY, only needed for iopt_run=5'

    ! Get Dominant Land Use categories (use)
    call get_landuse_netcdf(ncid, xdum ,   units, xstart, xend, ystart, yend)
    vegtyp = nint(xdum)
    ! print*, 'vegtyp(xstart,ystart) = ', vegtyp(xstart,ystart)

    ! Get Dominant Soil Type categories in the top layer (stl)
    call get_soilcat_netcdf(ncid, xdum ,   units, xstart, xend, ystart, yend)
    soltyp = nint(xdum)
    ! print*, 'soltyp(xstart,ystart) = ', soltyp(xstart,ystart)

    ! Close the NetCDF file
    ierr = nf90_close(ncid)
    if (ierr /= 0) stop "MODULE_NOAHLSM_HRLDAS_INPUT:  READLAND_HRLDAS:  NF90_CLOSE"

    ! Make sure vegtyp and soltyp are consistent when it comes to water points,
    ! by setting soil category to water when vegetation category is water, and
    ! vice-versa.
    !where (vegtyp == ISWATER .or. vegtyp == islake) soltyp = 14
    !where (soltyp == 14) vegtyp = ISWATER

  end subroutine readland_hrldas

!---------------------------------------------------------------------------------------------------------

  subroutine read_mmf_runoff(wrfinput_flnm,                            &
       xstart, xend,                                                   &
       ystart, yend,                                                   &
       fdepth,eqzwt,rechclim,riverbed)
    implicit none
    character(len=*),          intent(in)  :: wrfinput_flnm
    integer,                   intent(in)  :: xstart, xend, ystart, yend
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: fdepth
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: eqzwt
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: rechclim
    real,    dimension(xstart:xend,ystart:yend), intent(out) :: riverbed
    
    character(len=256) :: units
    integer :: ierr
    integer :: ncid
    real, dimension(xstart:xend,ystart:yend) :: xdum
    integer :: rank

    rank = 0


    ! Open the NetCDF file.
    if (rank == 0) write(*,'("wrfinput_flnm: ''", A, "''")') trim(wrfinput_flnm)
    ierr = nf90_open(wrfinput_flnm, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("read_mmf_runoff:  Problem opening wrfinput file: ''", A, "''")') trim(wrfinput_flnm)
       stop
    endif

    ! Get equilibrium water table depth (FDEPTH)
    call get_2d_netcdf("FDEPTH", ncid, fdepth,  units, xstart, xend, ystart, yend, FATAL, ierr)

    ! Get equilibrium water table depth (EQZWT)
    call get_2d_netcdf("EQZWT", ncid, eqzwt,  units, xstart, xend, ystart, yend, FATAL, ierr)

    ! Get water table depth (RECHCLIM)
    call get_2d_netcdf("RECHCLIM", ncid, rechclim,  units, xstart, xend, ystart, yend, FATAL, ierr)

    ! Get equilibrium water table depth (RIVERBED)
    call get_2d_netcdf("RIVERBED", ncid, riverbed,  units, xstart, xend, ystart, yend, FATAL, ierr)

    ! Close the NetCDF file
    ierr = nf90_close(ncid)
    if (ierr /= 0) stop "MODULE_HRLDAS_NETCDF_IO:  READ_MMF_RUNOFF:  NF90_CLOSE"


  end subroutine read_mmf_runoff

!---------------------------------------------------------------------------------------------------------
  subroutine read_crop_input(wrfinput_flnm,                            &
       xstart, xend,                                                   &
       ystart, yend,                                                   &
       croptype,planting,harvest,season_gdd)
    implicit none
    character(len=*),          intent(in)  :: wrfinput_flnm
    integer,                   intent(in)  :: xstart, xend, ystart, yend
    real,    dimension(xstart:xend,5,ystart:yend), intent(out) :: croptype
    real,    dimension(xstart:xend,  ystart:yend), intent(out) :: planting
    real,    dimension(xstart:xend,  ystart:yend), intent(out) :: harvest
    real,    dimension(xstart:xend,  ystart:yend), intent(out) :: season_gdd
    
    character(len=256) :: units
    character(len=24)  :: name
    integer :: ierr,iret
    integer :: ncid, varid, icrop
    real, dimension(xstart:xend,ystart:yend,5) :: xdum
    integer :: rank

    rank = 0


    ! Open the NetCDF file.
    if (rank == 0) write(*,'("wrfinput_flnm: ''", A, "''")') trim(wrfinput_flnm)
    ierr = nf90_open(wrfinput_flnm, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("read_mmf_runoff:  Problem opening wrfinput file: ''", A, "''")') trim(wrfinput_flnm)
       stop
    endif

! Get crop type data (CROPTYPE)
    name = "CROPTYPE"
    iret = nf90_inq_varid(ncid,  name,  varid)
    if (iret == 0) then
      ierr = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,5/))
      do icrop = 1,5
        croptype(:,icrop,:) = xdum(:,:,icrop)
      end do
    else
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file. Using default values."
    endif

! Get planting date (PLANTING)
    name = "PLANTING"
    iret = nf90_inq_varid(ncid,  name,  varid)
    if (iret == 0) then
      ierr = nf90_get_var(ncid, varid, planting, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    else
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file. Using default values."
    endif

! Get harvest date (HARVEST)
    name = "HARVEST"
    iret = nf90_inq_varid(ncid,  name,  varid)
    if (iret == 0) then
      ierr = nf90_get_var(ncid, varid, harvest, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    else
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file. Using default values."
    endif

! Get seasonal growing degree days (SEASON_GDD)
    name = "SEASON_GDD"
    iret = nf90_inq_varid(ncid,  name,  varid)
    if (iret == 0) then
      ierr = nf90_get_var(ncid, varid, season_gdd, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    else
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file. Using default values."
    endif

! Close the NetCDF file
    ierr = nf90_close(ncid)
    if (ierr /= 0) stop "MODULE_NOAHLSM_HRLDAS_INPUT:  read_crop_input:  NF90_CLOSE"


  end subroutine read_crop_input

!---------------------------------------------------------------------------------------------------------

  subroutine read_3d_soil(spatial_filename,xstart, xend,ystart, yend,           &
                          nsoil,bexp_3d,smcdry_3d,smcwlt_3d,smcref_3d,smcmax_3d,  &
		          dksat_3d,dwsat_3d,psisat_3d,quartz_3d,refdk_2d,refkdt_2d)
    implicit none
    character(len=*),          intent(in)  :: spatial_filename
    integer,                   intent(in)  :: xstart, xend, ystart, yend
    integer,                   intent(in)  :: nsoil
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: bexp_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: smcdry_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: smcwlt_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: smcref_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: smcmax_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: dksat_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: dwsat_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: psisat_3d
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: quartz_3d
    real,    dimension(xstart:xend,ystart:yend), intent(out)       :: refdk_2d
    real,    dimension(xstart:xend,ystart:yend), intent(out)       :: refkdt_2d
    
    character(len=24)  :: name
    character(len=256) :: units
    integer :: ierr,iret, varid,isoil
    integer :: ncid
    real, dimension(xstart:xend,ystart:yend,nsoil) :: xdum

    ierr = nf90_open(spatial_filename, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("read_3d_soil:  Problem opening 3d soil file: ''", A, "''")') trim(spatial_filename)
       stop
    endif

    name = "bexp"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      bexp_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "smcdry"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      smcdry_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "smcwlt"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      smcwlt_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "smcref"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      smcref_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "smcmax"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      smcmax_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "dksat"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      dksat_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "dwsat"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      dwsat_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "psisat"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      psisat_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "quartz"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, xdum, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,nsoil/))
    
    do isoil = 1,4
      quartz_3d(:,isoil,:) = xdum(:,:,isoil)
    end do

    name = "refdk"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, refdk_2d, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    
    name = "refkdt"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, refkdt_2d, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    
    ! Close the NetCDF file
    ierr = nf90_close(ncid)
    if (ierr /= 0) stop "MODULE_NOAHLSM_HRLDAS_INPUT:  read_3d_soil:  NF90_CLOSE"


  end subroutine read_3d_soil

!---------------------------------------------------------------------------------------------------------

  subroutine read_soil_composition(spatial_filename,xstart, xend,ystart, yend,           &
                                   nsoil,ivgtyp,isice,iswater,soilcomp)
    implicit none
    character(len=*),          intent(in)  :: spatial_filename
    integer,                   intent(in)  :: xstart, xend, ystart, yend
    integer,                   intent(in)  :: nsoil
    integer, dimension(xstart:xend      ,ystart:yend), intent(in)  :: ivgtyp
    integer,                   intent(in)  :: isice
    integer,                   intent(in)  :: iswater
    real,    dimension(xstart:xend,2*nsoil,ystart:yend), intent(out) :: soilcomp
    
    real,    dimension(xstart:xend,ystart:yend,2*nsoil) :: soilcomp_in
    
    character(len=24)  :: name
    character(len=256) :: units
    integer :: ierr,iret, varid,isoil
    integer :: ncid

    ierr = nf90_open(spatial_filename, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("read_soil_composition:  Problem opening soil composition file: ''", A, "''")') trim(spatial_filename)
       stop
    endif

    name = "SOILCOMP"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "read_soil_composition:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, soilcomp_in, start=(/xstart,ystart,1,1/), count=(/xend-xstart+1,yend-ystart+1,2*nsoil,1/))
    
    ! Map values

    do isoil = 1,2*nsoil
      
      soilcomp(:,isoil,:) = soilcomp_in(:,:,isoil)

    end do

    ! Remove any bad values

    do isoil = 1,nsoil
       
      where(ivgtyp /= isice .and. ivgtyp /= iswater .and. (soilcomp(:,isoil  ,:) <= 0) ) &
          soilcomp(:,isoil,:) = 41.0 
      where(ivgtyp /= isice .and. ivgtyp /= iswater .and. (soilcomp(:,isoil+nsoil,:) <= 0) ) &
          soilcomp(:,isoil+nsoil,:) = 18.0 

    end do

    ! Close the NetCDF file
    ierr = nf90_close(ncid)
    if (ierr /= 0) stop "MODULE_NOAHLSM_HRLDAS_INPUT:  read_soil_components:  NF90_CLOSE"


  end subroutine read_soil_composition

!---------------------------------------------------------------------------------------------------------

  subroutine read_soil_texture(spatial_filename,xstart, xend,ystart, yend,           &
                          nsoil,ivgtyp,soilcl1,soilcl2,soilcl3,soilcl4,isice,iswater)
    implicit none
    character(len=*),          intent(in)  :: spatial_filename
    integer,                   intent(in)  :: xstart, xend, ystart, yend
    integer,                   intent(in)  :: nsoil
    integer, dimension(xstart:xend      ,ystart:yend), intent(in)    :: ivgtyp
    real, dimension(xstart:xend,ystart:yend), intent(inout) :: soilcl1
    real, dimension(xstart:xend,ystart:yend), intent(inout) :: soilcl2
    real, dimension(xstart:xend,ystart:yend), intent(inout) :: soilcl3
    real, dimension(xstart:xend,ystart:yend), intent(inout) :: soilcl4
    integer,                   intent(in)  :: isice
    integer,                   intent(in)  :: iswater

    character(len=24)  :: name
    character(len=256) :: units
    integer :: ierr,iret, varid,isoil
    integer :: ncid
    
    soilcl1 = -999.
    soilcl2 = -999.
    soilcl3 = -999.
    soilcl4 = -999.

    ierr = nf90_open(spatial_filename, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("read_soil_composition:  Problem opening soil level texture file: ''", A, "''")') trim(spatial_filename)
       stop
    endif

    name = "SOILCL1"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "read_soil_composition:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, soilcl1, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,1/))
    
    where(soilcl1 < 0.5)  soilcl1 = 6.
    where(soilcl1 > 12.5) soilcl1 = 6.
    where(ivgtyp == isice   ) soilcl1 = 16. 
    where(ivgtyp == iswater ) soilcl1 = 14. 

    name = "SOILCL2"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "read_soil_composition:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, soilcl2, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,1/))
    
    where(soilcl2 < 0.5)  soilcl2 = 6.
    where(soilcl2 > 12.5) soilcl2 = 6.
    where(ivgtyp == isice   ) soilcl2 = 16. 
    where(ivgtyp == iswater ) soilcl2 = 14. 
    

    name = "SOILCL3"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "read_soil_composition:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, soilcl3, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,1/))
    
    where(soilcl3 < 0.5)  soilcl3 = 6.
    where(soilcl3 > 12.5) soilcl3 = 6.
    where(ivgtyp == isice   ) soilcl3 = 16. 
    where(ivgtyp == iswater ) soilcl3 = 14. 
    

    name = "SOILCL4"
    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
      print*, 'ncid = ', ncid
      write(*,*) "read_soil_composition:  Problem finding variable '"//trim(name)//"' in NetCDF file."
      stop
    endif

    iret = nf90_get_var(ncid, varid, soilcl4, start=(/xstart,ystart,1/), count=(/xend-xstart+1,yend-ystart+1,1/))
    
    where(soilcl4 < 0.5)  soilcl4 = 6.
    where(soilcl4 > 12.5) soilcl4 = 6.
    where(ivgtyp == isice   ) soilcl4 = 16. 
    where(ivgtyp == iswater ) soilcl4 = 14. 
            
    ! Close the NetCDF file
    ierr = nf90_close(ncid)
    if (ierr /= 0) stop "MODULE_NOAHLSM_HRLDAS_INPUT:  read_soil_texture:  NF90_CLOSE"


  end subroutine read_soil_texture

!---------------------------------------------------------------------------------------------------------

  subroutine get_landuse_netcdf(ncid, array, units, xstart, xend, ystart, yend)
    implicit none
    integer, intent(in) :: ncid
    integer, intent(in) :: xstart, xend, ystart, yend
    real, dimension(xstart:xend,ystart:yend), intent(out) :: array
    character(len=256), intent(out) :: units
    integer :: iret, varid
    character(len=24), parameter :: name = "IVGTYP"

    units = " "

    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    if (iret /= 0) then
       print*, 'name = "', trim(name)//'"'
       stop "MODULE_NOAHLSM_HRLDAS_INPUT:  get_landuse_netcdf:  nf90_inq_varid"
    endif

    iret = nf90_get_var(ncid, varid, array, (/xstart, ystart/), (/xend-xstart+1, yend-ystart+1/))
    if (iret /= 0) then
       print*, 'name = "', trim(name)//'"'
       stop "MODULE_NOAHLSM_HRLDAS_INPUT:  get_landuse_netcdf:  nf90_get_var"
    endif

  end subroutine get_landuse_netcdf

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine get_soilcat_netcdf(ncid, array, units, xstart, xend, ystart, yend)
    implicit none
    integer, intent(in) :: ncid
    integer, intent(in) :: xstart, xend, ystart, yend
    real, dimension(xstart:xend,ystart:yend), intent(out) :: array
    character(len=256), intent(out) :: units
    integer :: iret, varid
    character(len=24), parameter :: name = "ISLTYP"

    units = " "

    iret = nf90_inq_varid(ncid,  trim(name),  varid)
    call error_handler(iret, "Problem finding variable '"//trim(name)//"' in the wrfinput file.")

    iret = nf90_get_var(ncid, varid, array, (/xstart, ystart/), (/xend-xstart+1, yend-ystart+1/))
    call error_handler(iret, "Problem retrieving variable "//trim(name)//" from the wrfinput file.")

  end subroutine get_soilcat_netcdf

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine get_2d_netcdf(name, ncid, array, units, xstart, xend, ystart, yend, &
       fatal_if_error, ierr)
    implicit none
    character(len=*), intent(in) :: name
    integer, intent(in) :: ncid
    integer, intent(in) :: xstart, xend, ystart, yend
    real, dimension(xstart:xend,ystart:yend), intent(out) :: array
    character(len=*), intent(out) :: units
    integer :: iret, varid
    ! FATAL_IF_ERROR:  an input code value:
    !      .TRUE. if an error in reading the data should stop the program.
    !      Otherwise the, IERR error flag is set, but the program continues.
    logical, intent(in) :: fatal_if_error 
    integer, intent(out) :: ierr
    units = " "
    

    iret = nf90_inq_varid(ncid,  name,  varid)
    if (iret /= 0) then
       if (FATAL_IF_ERROR) then
          print*, 'ncid = ', ncid
          call error_handler(iret, "MODULE_HRLDAS_NETCDF_IO:  Problem finding variable '"//trim(name)//"' in NetCDF file.")
       else
          ierr = iret
          return
       endif
    endif

    iret = nf90_get_att(ncid, varid, "units", units)
    if (iret /= 0) units = "units unknown"
!KWM    if (iret /= 0) then
!KWM       if (FATAL_IF_ERROR) then
!KWM          print*, 'name = "', trim(name)//'"'
!KWM          stop "MODULE_NOAHLSM_HRLDAS_INPUT:  get_2d_netcdf:  nf90_get_att:  units."
!KWM       else
!KWM          ierr = iret
!KWM          return
!KWM       endif
!KWM    endif

    iret = nf90_get_var(ncid, varid, values=array, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    if (iret /= 0) then
       if (FATAL_IF_ERROR) then
          print*, 'ncid =', ncid
          call error_handler(iret, "MODULE_HRLDAS_NETCDF_IO:  Problem retrieving variable '"//trim(name)//"' from NetCDF file.")
       else
          ierr = iret
          return
       endif
    endif

    ierr = 0;
  end subroutine get_2d_netcdf

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine get_netcdf_soillevel(name, ncid, array, units, xstart, xend, ystart, yend, fatal_if_error, ierr)
    implicit none
    character(len=*), intent(in) :: name
    integer, intent(in) :: ncid
    integer, intent(in) :: xstart, xend, ystart, yend
    real, dimension(xstart:xend,4,ystart:yend), intent(out) :: array
    character(len=256), intent(out) :: units
    ! FATAL_IF_ERROR:  an input code value:
    !      .TRUE. if an error in reading the data should stop the program.
    !      Otherwise the, IERR error flag is set, but the program continues.
    logical, intent(in) :: fatal_if_error 
    integer, intent(out) :: ierr

    integer :: iret, varid, isoil
    real:: insoil(xstart:xend,ystart:yend,4)

    units = " "


    iret = nf90_inq_varid(ncid,  name,  varid)
    if (iret /= 0) then
       if (FATAL_IF_ERROR) then
          print*, 'name = "', trim(name)//'"'
          stop "MODULE_NOAHLSM_HRLDAS_INPUT:  get_2d_netcdf:  nf90_inq_varid"
       else
          ierr = iret
          return
       endif
    endif

    iret = nf90_get_att(ncid, varid, "units", units)
    if (iret /= 0) units = "units unknown"

    iret = nf90_get_var(ncid, varid, values=insoil, start=(/xstart,ystart,1,1/), count=(/xend-xstart+1,yend-ystart+1,4,1/))
    do isoil = 1,4
      array(:,isoil,:) = insoil(:,:,isoil)
    end do
    if (iret /= 0) then
       if (FATAL_IF_ERROR) then
          print*, 'name = "', trim(name)//'"'
          print*, 'varid =', varid
          print*, trim(nf90_strerror(iret))
          stop "MODULE_NOAHLSM_HRLDAS_INPUT:  get_2d_netcdf:  nf90_get_var"
       else
          ierr = iret
          return
       endif
    endif

    ierr = 0;
  end subroutine get_netcdf_soillevel

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine readinit_hrldas(netcdf_flnm, xstart, xend, ystart, yend, nsoil, sldpth, target_date, &
       ldasin_version, smc, stc, cmc, t1, weasd, snodep, fndsnowh)
    implicit none
    character(len=*),                                  intent(in)  :: netcdf_flnm
    integer,                                           intent(in)  :: xstart, xend
    integer,                                           intent(in)  :: ystart, yend
    integer,                                           intent(in)  :: nsoil
    real,    dimension(nsoil),                         intent(in)  :: sldpth
    character(len=*),                                  intent(in)  :: target_date
    
    integer,                                           intent(out) :: ldasin_version
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: smc
    real,    dimension(xstart:xend,nsoil,ystart:yend), intent(out) :: stc
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: cmc
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: t1
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: weasd
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: snodep
    logical,                                           intent(out) :: fndsnowh

    character(len=256) :: titlestr
    character(len=256) :: units
    character(len=8)   :: name
    character(len=256) :: ldasin_llanduse

    integer :: ierr, ncid, ierr_snodep, varid
    integer :: idx, isoil
    real, dimension(100) :: layer_bottom
    real, dimension(100) :: layer_top
    real, dimension(4)   :: dzs

    real, dimension(xstart:xend, ystart:yend, 4) :: insoil
    real, dimension(xstart:xend, 4, ystart:yend) :: soildummy
    integer :: rank

    !
    ! Open the NetCDF LDASIN file.
    !

    rank = 0
    ierr = nf90_open(netcdf_flnm, NF90_NOWRITE, ncid)
    if (rank == 0) write(*,'("netcdf_flnm: ''", A, "''")') trim(netcdf_flnm)
    if (ierr /= 0) then
       if (rank == 0) write(*,'("Problem opening netcdf file: ''", A, "''")') trim(netcdf_flnm)
       stop
    endif

    !
    ! Check the NetCDF LDASIN file for a version number.
    !

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "TITLE", titlestr)
    if (ierr /= 0) then
       write(*,'("WARNING:  LDASIN file does not have TITLE attribute.")')
       write(*,'("          This probably means that LDASIN files are from an older release.")')
       write(*,'("          I assume you know what you are doing.")')
       ldasin_version = 0
    else
       write(*,'("LDASIN TITLE attribute: ", A)') trim(titlestr)
       ! Pull out the version number, assuming that the version is identified by vYYYYMMDD, and 
       ! based on a search for the string "v20".
       idx = index(trim(titlestr), "v20")
       if (idx <= 0) then
          write(*,'("WARNING:  LDASIN file has a perverse version identifier")')
          !  write(*,'("          I assume you know what you are doing.")')
          ! stop
       else
          read(titlestr(idx+1:), '(I8)', iostat=ierr) ldasin_version
          if (ierr /= 0) then
             write(*,'("WARNING:  LDASIN file has a perverse version identifier")')
             !  write(*,'("          I assume you know what you are doing.")')
             ! stop
          endif
       endif
    endif
    write(*, '("ldasin_version = ", I8)') ldasin_version

    ierr = nf90_get_att(ncid, NF90_GLOBAL, "MMINLU", ldasin_llanduse)
    if (ierr /= 0) then
       write(*,'("WARNING:  LDASIN file does not have MMINLU attribute.")')
       write(*,'("          This probably means that LDASIN files are from an older release.")')
       write(*,'("          I assume you know what you are doing.")')
    else
       write(*,'("LDASIN MMNINLU attribute: ", A)') ldasin_llanduse
    endif

    call get_2d_netcdf("CANWAT", ncid, cmc,     units, xstart, xend, ystart, yend, FATAL, ierr)
    call get_2d_netcdf("TSK",    ncid, t1,      units, xstart, xend, ystart, yend, FATAL, ierr)
    call get_2d_netcdf("SNOW",   ncid, weasd,   units, xstart, xend, ystart, yend, FATAL, ierr)
! MB: assume in mm in v3.7
!    if (trim(units) == "m") then
!       ! No conversion necessary
!    else if (trim(units) == "mm") then
!       ! convert WEASD from mm to m
!       weasd = weasd * 1.E-3
!    else if (trim(units) == "kg m{-2}") then
!       ! convert WEASD from mm to m
!       weasd = weasd * 1.E-3
!    else if (trim(units) == "kg m-2") then
!       ! convert WEASD from mm to m
!       weasd = weasd * 1.E-3
!    else if (trim(units) == "kg/m2") then
!       ! convert WEASD from mm to m
!       weasd = weasd * 1.E-3
!    else
!       print*, 'units = "'//trim(units)//'"'
!       stop "Unrecognized units on WEASD"
!    endif

    snodep = 0.0
    call get_2d_netcdf("SNODEP",     ncid, snodep,   units, xstart, xend, ystart, yend, NOT_FATAL, ierr_snodep)
    fndsnowh = .true.
    if (ierr_snodep /= 0) fndsnowh = .false.

    ! Get the interfaces from the input file (not the variable as of v3.7)
    
    ierr = nf90_inq_varid(ncid,  "DZS",  varid)
    ierr = nf90_get_var(ncid, varid, values=dzs, start=(/1/), count=(/4/))
    
    layer_top(1) = 0.0
    layer_bottom(1) = dzs(1)
    do isoil = 2, 4
      layer_top(isoil) = layer_bottom(isoil-1)
      layer_bottom(isoil) = layer_top(isoil) + dzs(isoil)
    end do
	
    call get_netcdf_soillevel("TSLB", ncid, soildummy, units,  xstart, xend, ystart, yend, FATAL, ierr)
    
    write(*, '("layer_bottom(1:4) = ", 4F9.4)') layer_bottom(1:4)
    write(*, '("layer_top(1:4)    = ", 4F9.4)') layer_top(1:4)
    write(*, '("Soil depth = ", 10F12.6)') sldpth
    
    call init_interp(xstart, xend, ystart, yend, nsoil, sldpth, stc, 4, soildummy, layer_bottom(1:4), layer_top(1:4))

    call get_netcdf_soillevel("SMOIS", ncid, soildummy, units,  xstart, xend, ystart, yend, FATAL, ierr)

    call init_interp(xstart, xend, ystart, yend, nsoil, sldpth, smc, 4, soildummy, layer_bottom(1:4), layer_top(1:4))

    ierr = nf90_close(ncid)
  end subroutine readinit_hrldas

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine init_interp(xstart, xend, ystart, yend, nsoil, sldpth, var, nvar, src, layer_bottom, layer_top)
    implicit none
    integer, intent(in)    :: xstart, xend, ystart, yend, nsoil, nvar
    real, dimension(nsoil) :: sldpth ! the thickness of each layer
    real, dimension(xstart:xend, nsoil, ystart:yend), intent(out) :: var
    real, dimension(xstart:xend, nvar, ystart:yend ), intent(in)  :: src
    real, dimension(nvar),                            intent(in)  :: layer_bottom ! The depth from the surface of each layer bottom.
    real, dimension(nvar),                            intent(in)  :: layer_top    ! The depth from the surface of each layer top.
    integer :: i, j, k, kk, ktop, kbottom
    real, dimension(nsoil) :: dst_centerpoint
    real, dimension(nvar)  :: src_centerpoint
    real :: fraction
    integer :: ierr
    integer :: rank

    rank = 0

    do k = 1, nsoil
       if (k==1) then
          dst_centerpoint(k) = sldpth(k)/2.
       else
          dst_centerpoint(k) = sldpth(k)/2. + sum(sldpth(1:k-1))
       endif
       if (rank == 0) print*, 'k, dst_centerpoint(k) = ', k, dst_centerpoint(k)
    enddo
    print*

    do k = 1, nvar
       src_centerpoint(k) = 0.5*(layer_bottom(k)+layer_top(k))
       if (rank == 0) print*, 'k, src_centerpoint(k) = ', k, src_centerpoint(k)
    enddo

    KLOOP : do k = 1, nsoil

       if (dst_centerpoint(k) < src_centerpoint(1)) then
          ! If the center of the destination layer is closer to the surface than
          ! the center of the topmost source layer, then simply set the 
          ! value of the destination layer equal to the topmost source layer:
          if (rank == 0) then
             print'("Shallow destination layer:  Taking destination layer at ",F7.4, " from source layer at ", F7.4)', &
                  dst_centerpoint(k), src_centerpoint(1)
          endif
          var(:,k,:) = src(:,1,:)
          cycle KLOOP
       endif

       if (dst_centerpoint(k) > src_centerpoint(nvar)) then
          ! If the center of the destination layer is deeper than
          ! the center of the deepest source layer, then simply set the 
          ! value of the destination layer equal to the deepest source layer:
          if (rank == 0) then
             print'("Deep destination layer:  Taking destination layer at ",F7.4, " from source layer at ", F7.4)', &
                  dst_centerpoint(k), src_centerpoint(nvar)
          endif
          var(:,k,:) = src(:,nvar,:)
          cycle KLOOP
       endif

       ! Check if the center of the destination layer is "close" to the center
       ! of a source layer.  If so, simply set the value of the destination layer
       ! equal to the value of that close soil layer:
       do kk = 1, nvar
          if (abs(dst_centerpoint(k)-src_centerpoint(kk)) < 0.01) then
             if (rank == 0) then
                print'("(Near) match for destination layer:  Taking destination layer at ",F7.4, " from source layer at ", F7.4)', &
                     dst_centerpoint(k), src_centerpoint(kk)
             endif
             var(:,k,:) = src(:,kk,:)
             cycle KLOOP
          endif
       enddo

       ! Otherwise, do a linear interpolation

       ! Get ktop, the index of the top bracketing layer from the source dataset.
       ! Which from the bottom up, will be the first source level that is closer 
       ! to the surface than the destination level
       ktop = -99999
       TOPLOOP : do kk = nvar,1,-1
          if (src_centerpoint(kk) < dst_centerpoint(k)) then
             ktop = kk
             exit TOPLOOP
          endif
       enddo TOPLOOP
       if (ktop < -99998) stop "ktop problem"


       ! Get kbottom, the index of the bottom bracketing layer from the source dataset.
       ! Which, from the top down, will be the first source level that is deeper than
       ! the destination level
       kbottom = -99999
       BOTTOMLOOP : do kk = 1, nvar
          if ( src_centerpoint(kk) > dst_centerpoint(k) ) then
             kbottom = kk
             exit BOTTOMLOOP
          endif
       enddo BOTTOMLOOP
       if (kbottom < -99998) stop "kbottom problem"

       fraction = (src_centerpoint(kbottom)-dst_centerpoint(k)) / (src_centerpoint(kbottom)-src_centerpoint(ktop))

       ! print '(I2, 1x, 3F7.3, F8.5)', k, src_centerpoint(ktop), dst_centerpoint(k), src_centerpoint(kbottom), fraction

       if (rank == 0) then
          print '("dst(",I1,") = src(",I1,")*",F8.5," + src(",I1,")*",F8.5)', k, ktop, fraction, kbottom, (1.0-fraction)
       endif

       var(:,:,k) = (src(:,ktop,:)*fraction) + (src(:,kbottom,:)*(1.0-fraction))

    enddo KLOOP
     
  end subroutine init_interp

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine READVEG_HRLDAS(flnm, xstart, xend, ystart, yend, target_date, vegtyp, vegfra, lai, gvfmin, gvfmax)

    implicit none
    character(len=*),                                  intent(in)  :: flnm
    integer,                                           intent(in)  :: xstart, xend
    integer,                                           intent(in)  :: ystart, yend
    character(len=*),                                  intent(in)  :: target_date
    integer, dimension(xstart:xend,ystart:yend),       intent(in)  :: vegtyp
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: vegfra
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: lai
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: gvfmin
    real,    dimension(xstart:xend,ystart:yend),       intent(out) :: gvfmax

    character(len=8)   :: name
    character(len=256) :: units
    integer :: ierr

    integer :: ierr_vegfra
    integer :: ierr_lai

    integer :: i, j
    integer :: iret, ncid

    ! Open the NetCDF file.
!KWM    write(*,'("flnm: ''", A, "''")') trim(flnm)
    iret = nf90_open(flnm, NF90_NOWRITE, ncid)
    if (iret /= 0) then
       write(*,'("READVEG_HRLDAS:  Problem opening netcdf file: ''", A, "''")') trim(flnm)
       stop
    endif

    call get_2d_netcdf("VEGFRA",     ncid, vegfra,     units, xstart, xend, ystart, yend, NOT_FATAL, ierr_vegfra)
    call get_2d_netcdf("LAI",        ncid, lai,      units, xstart, xend, ystart, yend, NOT_FATAL, ierr_lai)

    if (ierr_vegfra == 0) then
       ! vegfra = vegfra * 1.E-2 ! convert from percent to fraction
    else if (ierr_vegfra /= 0) then
       ! Get it from tables
       ! print*,' READVEG_HRLDAS:  VEGFRA not found.  Initializing VEGFRA from table SHDTBL.'
       do i = xstart, xend
          do j = ystart, yend
!KWM             vegfra(i,j) = shdtbl(vegtyp(i,j))
          enddo
       enddo
    endif
    if (ierr_lai /= 0) then
       ! Get it from tables
       ! print*,' READVEG_HRLDAS:  LAI not found.  Initializing LAI from table LAITBL.'
       do i = xstart, xend
          do j = ystart, yend
! Fixme for wrfcode input
!             lai(i,j) = laitbl(vegtyp(i,j))
          enddo
       enddo
    endif

    ! Get Minimum Green Vegetation Fraction SHDMIN
    call get_2d_netcdf("SHDMIN", ncid, gvfmin,   units, xstart, xend, ystart, yend, FATAL, ierr)

    ! Get Minimum Green Vegetation Fraction SHDMAX
    call get_2d_netcdf("SHDMAX", ncid, gvfmax,   units, xstart, xend, ystart, yend, FATAL, ierr)

    iret = nf90_close(ncid)
  end subroutine READVEG_HRLDAS

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine READFORC_HRLDAS(flnm_template, forcing_timestep, target_date, xstart, xend, ystart, yend,  &
       forcing_name_T,forcing_name_Q,forcing_name_U,forcing_name_V,forcing_name_P, &
       forcing_name_LW,forcing_name_SW,forcing_name_PR,forcing_name_SN, &
       t,q,u,v,p,lw,sw,pcp,snow,vegfra,update_veg,lai,update_lai,reset_spinup_date,startdate)
    use kwm_string_utilities
    implicit none

    character(len=*),                   intent(in)  :: flnm_template
    integer,                            intent(in)  :: forcing_timestep
    integer,                            intent(in)  :: xstart, xend
    integer,                            intent(in)  :: ystart, yend
    character(len=19),                  intent(in)  :: target_date, startdate ! (YYYY-MM-DD_hh:mm:ss)
    character(len=256),                 intent(in)  :: forcing_name_T
    character(len=256),                 intent(in)  :: forcing_name_Q
    character(len=256),                 intent(in)  :: forcing_name_U
    character(len=256),                 intent(in)  :: forcing_name_V
    character(len=256),                 intent(in)  :: forcing_name_P
    character(len=256),                 intent(in)  :: forcing_name_LW
    character(len=256),                 intent(in)  :: forcing_name_SW
    character(len=256),                 intent(in)  :: forcing_name_PR
    character(len=256),                 intent(in)  :: forcing_name_SN

    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: t
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: q
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: u
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: v
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: p
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: lw
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: sw
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: pcp
    real,             dimension(xstart:xend,ystart:yend), intent(out)   :: snow
    real,             dimension(xstart:xend,ystart:yend), intent(inout) :: lai    !Barlage v3.7: change to inout
    real,             dimension(xstart:xend,ystart:yend), intent(inout) :: vegfra
    logical,                            intent(in)  :: update_veg, update_lai  ! Barlage v3.7: for veg read control
    logical,                                              intent(inout) :: reset_spinup_date

    character(len=256) :: flnm
    character(len=256) :: units
    character(len=256) :: nextflnm
    integer :: ierr
    integer :: ncid
    integer :: rank

    type(inputstruct) :: lastread = inputstruct("0000-00-00_00:00:00", &
         null(), null(), null(), null(), null(), null(), null(), null(), null(), null(), null() )
    type(inputstruct) :: nextread= inputstruct("0000-00-00_00:00:00", &
         null(), null(), null(), null(), null(), null(), null(), null(), null(), null(), null() )

    if(reset_spinup_date) lastread%read_date = startdate
    reset_spinup_date = .false.
!KWM    print*, 'target_date        = ', target_date
!KWM    print*, 'lastread%read_date = ', lastread%read_date
!KWM    print*, 'nextread%read_date = ', nextread%read_date



    if (target_date > nextread%read_date ) then
       !
       ! We've advanced beyond the date of the end-bracketing data in memory.
       ! Read the next (later) forcing data, and put the data into the nextread
       ! structure.
       !
       if (nextread%read_date /= "0000-00-00_00:00:00") then
          ! Clear the old lastread data
          call clear_inputstruct(lastread)

          ! Copy nextread to lastread
          lastread = nextread
       
          ! Clear nextread
          call nullify_inputstruct(nextread)
       endif

       ! Guess the next read date (from the last read date and the forcing timestep).
       ! If there is no last date, assume we're at the beginning of our processing
       ! and take the target_date as the first timestep, for which forcing data
       ! must be available.
     
       if (lastread%read_date == "0000-00-00_00:00:00") then
          nextread%read_date = target_date
       else
          call geth_newdate(nextread%read_date, lastread%read_date, forcing_timestep)
       endif

       ! Build a file name
       flnm = flnm_template


       if(mod(forcing_timestep,3600) == 0) then
         call strrep(flnm, "<date>", nextread%read_date(1:4)//nextread%read_date(6:7)//nextread%read_date(9:10)//nextread%read_date(12:13))
       elseif(mod(forcing_timestep,60) == 0) then
         call strrep(flnm, "<date>", nextread%read_date(1:4)//nextread%read_date(6:7)//nextread%read_date(9:10)//nextread%read_date(12:13)//nextread%read_date(15:16))
       else
         call strrep(flnm, "<date>", nextread%read_date(1:4)//nextread%read_date(6:7)//nextread%read_date(9:10)//nextread%read_date(12:13)//nextread%read_date(15:16)//nextread%read_date(18:19))
       endif

       !print*, 'read file:  ', trim(flnm)
       ! Open the NetCDF file.
       ierr = nf90_open(flnm, NF90_NOWRITE, ncid)
       if (ierr /= 0) then
             write(*,'("A)  Problem opening netcdf file: ''", A, "''")') trim(flnm)
          stop
       endif

       ! Allocate space to hold data
       call allocate_inputstruct(nextread, xstart, xend, ystart, yend)

       ! Read the data
       call get_2d_netcdf(trim(forcing_name_T) , ncid, nextread%t,     units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_Q) , ncid, nextread%q,     units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_U) , ncid, nextread%u,     units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_V) , ncid, nextread%v,     units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_P) , ncid, nextread%p,     units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_LW), ncid, nextread%lw,    units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_SW), ncid, nextread%sw,    units, xstart, xend, ystart, yend, FATAL, ierr)
       call get_2d_netcdf(trim(forcing_name_PR), ncid, nextread%pcp,   units, xstart, xend, ystart, yend, FATAL, ierr)
       
       nextread%snow = 0.0  ! Assume zero in case not present
       call get_2d_netcdf(trim(forcing_name_SN), ncid, nextread%snow,  units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
       
       if(update_veg) then    ! Barlage v3.7: update only if dveg option is appropriate
       
         call get_2d_netcdf("VEGFRA",  ncid, nextread%vegfra,units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
         if (ierr /= 0) then
          ! print*, 'VEGFRA not found!'
          ! If we don't find a new VEGFRA, carry over the old one
          if (associated(lastread%vegfra)) then
             nextread%vegfra = lastread%vegfra
          else
             nextread%vegfra = vegfra
          endif
         endif

       endif
	 
       if(update_lai) then    ! Barlage v3.7: update only if dveg option is appropriate
	 
         call get_2d_netcdf("LAI",     ncid, nextread%lai,   units, xstart, xend, ystart, yend, NOT_FATAL, ierr)
         if (ierr /= 0) then
          ! print*, 'LAI not found!'
          ! If we don't find a new LAI, carry over the old one
          if (associated(lastread%lai)) then
            nextread%lai = lastread%lai
          else
            nextread%lai = lai
          endif
         endif

       endif
	 
       ! Close the file
       ierr = nf90_close(ncid)

    endif




    if (target_date == nextread%read_date) then
       !
       ! We have advanced to the later date of our bracketing times for interpolation.
       ! Take that data as is, no interpolation necessary, move that data into the 
       ! lastread structure, and return that data.
       !

       ! Fill the t, q, u, v, ... arrays with data from the nextread structure.
       call copyfrom_inputstruct(nextread, t, q, u, v, p, lw, sw, pcp, snow, vegfra, lai, &
                                 update_veg, update_lai, xstart, xend, ystart, yend)

       ! Clear the old lastread data
       call clear_inputstruct(lastread)

       ! Copy nextread to lastread
       lastread = nextread

       ! Set the nextread%read_date field to signal that we need to read
       nextread%read_date = "0000-00-00_00:00:00"

       ! Clear nextread
       call nullify_inputstruct(nextread)

    else if ( ( target_date > lastread%read_date ) .and. ( target_date < nextread%read_date ) ) then

       !
       ! We are at a Noah time step between the lastread data and the available nextread data.
       ! Do temporal interpolation and return the interpolated data.  Keep lastread
       ! and nextread as they were.
       !

       ! Fill the t, q, u, v, ... arrays with data interpolated between lastread and nextread times.
       call interpolate_inputstruct(lastread, nextread, target_date, &
            t, q, u, v, p, lw, sw, pcp, snow, vegfra, lai, update_veg, update_lai, xstart, xend, ystart, yend)

    else

       print*, 'target_date        = ', target_date
       print*, 'lastread%read_date = ', lastread%read_date
       print*, 'nextread%read_date = ', nextread%read_date

       STOP "We should not be here.  Problem with the logic of READFORC_SHORTER_TIMESTEP"

    endif

  end subroutine READFORC_HRLDAS

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine allocate_inputstruct(instruct, xstart, xend, ystart, yend)
    implicit none
    type(inputstruct)   :: instruct
    integer, intent(in) :: xstart
    integer, intent(in) :: xend
    integer, intent(in) :: ystart
    integer, intent(in) :: yend

    integer :: allostat

    allocate(instruct%t   (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%t"

    allocate(instruct%q   (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%q"

    allocate(instruct%u   (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%u"

    allocate(instruct%v   (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%v"

    allocate(instruct%p   (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%p"

    allocate(instruct%lw  (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%lw"

    allocate(instruct%sw  (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%sw"

    allocate(instruct%pcp (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%pcp"

    allocate(instruct%snow (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%snow"

    allocate(instruct%vegfra(xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%vegfra"

    allocate(instruct%lai (xstart:xend,ystart:yend), stat=allostat )
    if (allostat/=0) stop "Problem allocating instruct%lai"
  end subroutine allocate_inputstruct

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine copyfrom_inputstruct(instruct, t, q, u, v, p, lw, sw, pcp, snow, vegfra, lai, &
                                  update_veg, update_lai, xstart, xend, ystart, yend)
    implicit none
    type(inputstruct), intent(in) :: instruct
    integer,           intent(in) :: xstart, xend, ystart, yend
    logical,           intent(in)  :: update_veg, update_lai  ! Barlage v3.7: for veg read control
    real, dimension(xstart:xend,ystart:yend), intent(out) :: t, q, u, v, p, lw, sw, pcp, snow, vegfra, lai
    t    = instruct%t
    q    = instruct%q
    u    = instruct%u
    v    = instruct%v
    p    = instruct%p
    lw   = instruct%lw
    sw   = instruct%sw
    snow = instruct%snow
    pcp  = instruct%pcp
    if(update_veg) vegfra = instruct%vegfra
    if(update_lai)   lai  = instruct%lai
  end subroutine copyfrom_inputstruct

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine interpolate_inputstruct(instructA, instructB, target_date, &
       t, q, u, v, p, lw, sw, pcp, snow, vegfra, lai, update_veg, update_lai, xstart, xend, ystart, yend)
    implicit none
    type(inputstruct),                        intent(in)  :: instructA, instructB
    character(len=19),                        intent(in)  :: target_date
    integer,                                  intent(in)  :: xstart, xend, ystart, yend
    logical,                                  intent(in)  :: update_veg, update_lai  ! Barlage v3.7: for veg read control
    real, dimension(xstart:xend,ystart:yend), intent(out) :: t, q, u, v, p, lw, sw, pcp, snow, vegfra, lai

    integer :: idts, idts2
    real    :: fraction

    call geth_idts(target_date, instructA%read_date, idts)
    call geth_idts(instructB%read_date, instructA%read_date, idts2)

    fraction = real(idts2-idts)/real(idts2)
    t  = ( instructA%t  * fraction ) + ( instructB%t  * (1.0-fraction) )
    q  = ( instructA%q  * fraction ) + ( instructB%q  * (1.0-fraction) )
    u  = ( instructA%u  * fraction ) + ( instructB%u  * (1.0-fraction) )
    v  = ( instructA%v  * fraction ) + ( instructB%v  * (1.0-fraction) )
    p  = ( instructA%p  * fraction ) + ( instructB%p  * (1.0-fraction) )
    lw = ( instructA%lw * fraction ) + ( instructB%lw * (1.0-fraction) )
    sw = ( instructA%sw * fraction ) + ( instructB%sw * (1.0-fraction) )
    snow = instructA%snow
    pcp = instructA%pcp
    if(update_veg) vegfra = instructA%vegfra
    if(update_lai)   lai  = instructA%lai
  end subroutine interpolate_inputstruct

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine clear_inputstruct(instruct)
    implicit none
    type(inputstruct) :: instruct

    if (associated(instruct%t)) then
       deallocate(instruct%t)
       nullify(instruct%t)
    endif

    if (associated(instruct%q)) then
       deallocate(instruct%q)
       nullify(instruct%q)
    endif

    if (associated(instruct%u)) then
       deallocate(instruct%u)
       nullify(instruct%u)
    endif

    if (associated(instruct%v)) then
       deallocate(instruct%v)
       nullify(instruct%v)
    endif

    if (associated(instruct%p)) then
       deallocate(instruct%p)
       nullify(instruct%p)
    endif

    if (associated(instruct%lw)) then
       deallocate(instruct%lw)
       nullify(instruct%lw)
    endif

    if (associated(instruct%sw)) then
       deallocate(instruct%sw)
       nullify(instruct%sw)
    endif

    if (associated(instruct%pcp)) then
       deallocate(instruct%pcp)
       nullify(instruct%pcp)
    endif

    if (associated(instruct%snow)) then
       deallocate(instruct%snow)
       nullify(instruct%snow)
    endif

    if (associated(instruct%vegfra)) then
       deallocate(instruct%vegfra)
       nullify(instruct%vegfra)
    endif

    if (associated(instruct%lai)) then
       deallocate(instruct%lai)
       nullify(instruct%lai)
    endif
  end subroutine clear_inputstruct

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine nullify_inputstruct(instruct)
    implicit none
    type(inputstruct) :: instruct

    nullify(instruct%t)
    nullify(instruct%q)
    nullify(instruct%u)
    nullify(instruct%v)
    nullify(instruct%p)
    nullify(instruct%lw)
    nullify(instruct%sw)
    nullify(instruct%pcp)
    nullify(instruct%snow)
    nullify(instruct%vegfra)
    nullify(instruct%lai)
  end subroutine nullify_inputstruct

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine READSNOW_HRLDAS(flnm,xstart,xend,ystart,yend,target_date,weasd,snodep)
    implicit none

    character(len=*),                                     intent(in)  :: flnm
    integer,                                              intent(in)  :: xstart, xend
    integer,                                              intent(in)  :: ystart, yend
    character(len=*),                                     intent(in)  :: target_date
    real,             dimension(xstart:xend,ystart:yend), intent(out) :: weasd
    real,             dimension(xstart:xend,ystart:yend), intent(out) :: snodep

    character(len=256) :: units
    integer :: ierr
    integer :: ncid

    ! Open the NetCDF file.

    ierr = nf90_open(flnm, NF90_NOWRITE, ncid)
    if (ierr /= 0) then
       write(*,'("READSNOW_HRLDAS:  Problem opening netcdf file: ''", A, "''")') trim(flnm)
       stop
    endif

    call get_2d_netcdf("WEASD",  ncid, weasd,   units, xstart, xend, ystart, yend, FATAL, ierr)

    if (trim(units) == "m") then
       ! No conversion necessary
    else if (trim(units) == "mm") then
       ! convert WEASD from mm to m
       weasd = weasd * 1.E-3
    else if (trim(units) == "kg m{-2}") then
       ! convert WEASD from mm to m
       weasd = weasd * 1.E-3
    else if (trim(units) == "kg/m2") then
       ! convert WEASD from mm to m
       weasd = weasd * 1.E-3
    else
       print*, 'units = "'//trim(units)//'"'
       stop "Unrecognized units on WEASD"
    endif

    call get_2d_netcdf("SNODEP",     ncid, snodep,   units, xstart, xend, ystart, yend, NOT_FATAL, ierr)

    if (ierr /= 0) then
       ! Quick assumption regarding snow depth.
       snodep = weasd * 10.
    endif

    ierr = nf90_close(ncid)

  end subroutine READSNOW_HRLDAS

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine prepare_output_file_seq(outdir, version, igrid, &
       output_timestep, llanduse, split_output_count, hgrid, &
       ixfull, jxfull, ixpar, jxpar, xstartpar, ystartpar, iswater,  &
       mapproj, lat1, lon1, dx, dy, truelat1, truelat2, cen_lon,     &
       nsoil, nsnow, sldpth, startdate, date, spinup_loop, spinup_loops, &
       vegtyp, soltyp)
    ! To prepare the output file, we create the file, write dimensions and attributes, write the time variable.
    ! At the end of this routine, the output file is out of define mode.
    implicit none
!     NetCDF-3.
!
! netcdf version 3 fortran interface:
!

!
! external netcdf data types:
!
      integer nf_byte
      integer nf_int1
      integer nf_char
      integer nf_short
      integer nf_int2
      integer nf_int
      integer nf_float
      integer nf_real
      integer nf_double

      parameter (nf_byte = 1)
      parameter (nf_int1 = nf_byte)
      parameter (nf_char = 2)
      parameter (nf_short = 3)
      parameter (nf_int2 = nf_short)
      parameter (nf_int = 4)
      parameter (nf_float = 5)
      parameter (nf_real = nf_float)
      parameter (nf_double = 6)

!
! default fill values:
!
      integer           nf_fill_byte
      integer           nf_fill_int1
      integer           nf_fill_char
      integer           nf_fill_short
      integer           nf_fill_int2
      integer           nf_fill_int
      real              nf_fill_float
      real              nf_fill_real
      doubleprecision   nf_fill_double

      parameter (nf_fill_byte = -127)
      parameter (nf_fill_int1 = nf_fill_byte)
      parameter (nf_fill_char = 0)
      parameter (nf_fill_short = -32767)
      parameter (nf_fill_int2 = nf_fill_short)
      parameter (nf_fill_int = -2147483647)
      parameter (nf_fill_float = 9.9692099683868690e+36)
      parameter (nf_fill_real = nf_fill_float)
      parameter (nf_fill_double = 9.9692099683868690d+36)

!
! mode flags for opening and creating a netcdf dataset:
!
      integer nf_nowrite
      integer nf_write
      integer nf_clobber
      integer nf_noclobber
      integer nf_fill
      integer nf_nofill
      integer nf_lock
      integer nf_share
      integer nf_64bit_offset
      integer nf_sizehint_default
      integer nf_align_chunk
      integer nf_format_classic
      integer nf_format_64bit
      integer nf_diskless
      integer nf_mmap

      parameter (nf_nowrite = 0)
      parameter (nf_write = 1)
      parameter (nf_clobber = 0)
      parameter (nf_noclobber = 4)
      parameter (nf_fill = 0)
      parameter (nf_nofill = 256)
      parameter (nf_lock = 1024)
      parameter (nf_share = 2048)
      parameter (nf_64bit_offset = 512)
      parameter (nf_sizehint_default = 0)
      parameter (nf_align_chunk = -1)
      parameter (nf_format_classic = 1)
      parameter (nf_format_64bit = 2)
      parameter (nf_diskless = 8)
      parameter (nf_mmap = 16)

!
! size argument for defining an unlimited dimension:
!
      integer nf_unlimited
      parameter (nf_unlimited = 0)

!
! global attribute id:
!
      integer nf_global
      parameter (nf_global = 0)

!
! implementation limits:
!
      integer nf_max_dims
      integer nf_max_attrs
      integer nf_max_vars
      integer nf_max_name
      integer nf_max_var_dims

      parameter (nf_max_dims = 1024)
      parameter (nf_max_attrs = 8192)
      parameter (nf_max_vars = 8192)
      parameter (nf_max_name = 256)
      parameter (nf_max_var_dims = nf_max_dims)

!
! error codes:
!
      integer nf_noerr
      integer nf_ebadid
      integer nf_eexist
      integer nf_einval
      integer nf_eperm
      integer nf_enotindefine
      integer nf_eindefine
      integer nf_einvalcoords
      integer nf_emaxdims
      integer nf_enameinuse
      integer nf_enotatt
      integer nf_emaxatts
      integer nf_ebadtype
      integer nf_ebaddim
      integer nf_eunlimpos
      integer nf_emaxvars
      integer nf_enotvar
      integer nf_eglobal
      integer nf_enotnc
      integer nf_ests
      integer nf_emaxname
      integer nf_eunlimit
      integer nf_enorecvars
      integer nf_echar
      integer nf_eedge
      integer nf_estride
      integer nf_ebadname
      integer nf_erange
      integer nf_enomem
      integer nf_evarsize
      integer nf_edimsize
      integer nf_etrunc

      parameter (nf_noerr = 0)
      parameter (nf_ebadid = -33)
      parameter (nf_eexist = -35)
      parameter (nf_einval = -36)
      parameter (nf_eperm = -37)
      parameter (nf_enotindefine = -38)
      parameter (nf_eindefine = -39)
      parameter (nf_einvalcoords = -40)
      parameter (nf_emaxdims = -41)
      parameter (nf_enameinuse = -42)
      parameter (nf_enotatt = -43)
      parameter (nf_emaxatts = -44)
      parameter (nf_ebadtype = -45)
      parameter (nf_ebaddim = -46)
      parameter (nf_eunlimpos = -47)
      parameter (nf_emaxvars = -48)
      parameter (nf_enotvar = -49)
      parameter (nf_eglobal = -50)
      parameter (nf_enotnc = -51)
      parameter (nf_ests = -52)
      parameter (nf_emaxname = -53)
      parameter (nf_eunlimit = -54)
      parameter (nf_enorecvars = -55)
      parameter (nf_echar = -56)
      parameter (nf_eedge = -57)
      parameter (nf_estride = -58)
      parameter (nf_ebadname = -59)
      parameter (nf_erange = -60)
      parameter (nf_enomem = -61)
      parameter (nf_evarsize = -62)
      parameter (nf_edimsize = -63)
      parameter (nf_etrunc = -64)
!
! error handling modes:
!
      integer  nf_fatal
      integer nf_verbose

      parameter (nf_fatal = 1)
      parameter (nf_verbose = 2)

!
! miscellaneous routines:
!
      character*80   nf_inq_libvers
      external       nf_inq_libvers

      character*80   nf_strerror
!                         (integer             ncerr)
      external       nf_strerror

      logical        nf_issyserr
!                         (integer             ncerr)
      external       nf_issyserr

!
! control routines:
!
      integer         nf_inq_base_pe
!                         (integer             ncid,
!                          integer             pe)
      external        nf_inq_base_pe

      integer         nf_set_base_pe
!                         (integer             ncid,
!                          integer             pe)
      external        nf_set_base_pe

      integer         nf_create
!                         (character*(*)       path,
!                          integer             cmode,
!                          integer             ncid)
      external        nf_create

      integer         nf__create
!                         (character*(*)       path,
!                          integer             cmode,
!                          integer             initialsz,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__create

      integer         nf__create_mp
!                         (character*(*)       path,
!                          integer             cmode,
!                          integer             initialsz,
!                          integer             basepe,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__create_mp

      integer         nf_open
!                         (character*(*)       path,
!                          integer             mode,
!                          integer             ncid)
      external        nf_open

      integer         nf__open
!                         (character*(*)       path,
!                          integer             mode,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__open

      integer         nf__open_mp
!                         (character*(*)       path,
!                          integer             mode,
!                          integer             basepe,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__open_mp

      integer         nf_set_fill
!                         (integer             ncid,
!                          integer             fillmode,
!                          integer             old_mode)
      external        nf_set_fill

      integer         nf_set_default_format
!                          (integer             format,
!                          integer             old_format)
      external        nf_set_default_format

      integer         nf_redef
!                         (integer             ncid)
      external        nf_redef

      integer         nf_enddef
!                         (integer             ncid)
      external        nf_enddef

      integer         nf__enddef
!                         (integer             ncid,
!                          integer             h_minfree,
!                          integer             v_align,
!                          integer             v_minfree,
!                          integer             r_align)
      external        nf__enddef

      integer         nf_sync
!                         (integer             ncid)
      external        nf_sync

      integer         nf_abort
!                         (integer             ncid)
      external        nf_abort

      integer         nf_close
!                         (integer             ncid)
      external        nf_close

      integer         nf_delete
!                         (character*(*)       ncid)
      external        nf_delete

!
! general inquiry routines:
!

      integer         nf_inq
!                         (integer             ncid,
!                          integer             ndims,
!                          integer             nvars,
!                          integer             ngatts,
!                          integer             unlimdimid)
      external        nf_inq

! new inquire path

      integer nf_inq_path
      external nf_inq_path

      integer         nf_inq_ndims
!                         (integer             ncid,
!                          integer             ndims)
      external        nf_inq_ndims

      integer         nf_inq_nvars
!                         (integer             ncid,
!                          integer             nvars)
      external        nf_inq_nvars

      integer         nf_inq_natts
!                         (integer             ncid,
!                          integer             ngatts)
      external        nf_inq_natts

      integer         nf_inq_unlimdim
!                         (integer             ncid,
!                          integer             unlimdimid)
      external        nf_inq_unlimdim

      integer         nf_inq_format
!                         (integer             ncid,
!                          integer             format)
      external        nf_inq_format

!
! dimension routines:
!

      integer         nf_def_dim
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             len,
!                          integer             dimid)
      external        nf_def_dim

      integer         nf_inq_dimid
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             dimid)
      external        nf_inq_dimid

      integer         nf_inq_dim
!                         (integer             ncid,
!                          integer             dimid,
!                          character(*)        name,
!                          integer             len)
      external        nf_inq_dim

      integer         nf_inq_dimname
!                         (integer             ncid,
!                          integer             dimid,
!                          character(*)        name)
      external        nf_inq_dimname

      integer         nf_inq_dimlen
!                         (integer             ncid,
!                          integer             dimid,
!                          integer             len)
      external        nf_inq_dimlen

      integer         nf_rename_dim
!                         (integer             ncid,
!                          integer             dimid,
!                          character(*)        name)
      external        nf_rename_dim

!
! general attribute routines:
!

      integer         nf_inq_att
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len)
      external        nf_inq_att

      integer         nf_inq_attid
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             attnum)
      external        nf_inq_attid

      integer         nf_inq_atttype
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype)
      external        nf_inq_atttype

      integer         nf_inq_attlen
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             len)
      external        nf_inq_attlen

      integer         nf_inq_attname
!                         (integer             ncid,
!                          integer             varid,
!                          integer             attnum,
!                          character(*)        name)
      external        nf_inq_attname

      integer         nf_copy_att
!                         (integer             ncid_in,
!                          integer             varid_in,
!                          character(*)        name,
!                          integer             ncid_out,
!                          integer             varid_out)
      external        nf_copy_att

      integer         nf_rename_att
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        curname,
!                          character(*)        newname)
      external        nf_rename_att

      integer         nf_del_att
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name)
      external        nf_del_att

!
! attribute put/get routines:
!

      integer         nf_put_att_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             len,
!                          character(*)        text)
      external        nf_put_att_text

      integer         nf_get_att_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          character(*)        text)
      external        nf_get_att_text

      integer         nf_put_att_int1
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          nf_int1_t           i1vals(1))
      external        nf_put_att_int1

      integer         nf_get_att_int1
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          nf_int1_t           i1vals(1))
      external        nf_get_att_int1

      integer         nf_put_att_int2
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          nf_int2_t           i2vals(1))
      external        nf_put_att_int2

      integer         nf_get_att_int2
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          nf_int2_t           i2vals(1))
      external        nf_get_att_int2

      integer         nf_put_att_int
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          integer             ivals(1))
      external        nf_put_att_int

      integer         nf_get_att_int
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             ivals(1))
      external        nf_get_att_int

      integer         nf_put_att_real
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          real                rvals(1))
      external        nf_put_att_real

      integer         nf_get_att_real
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          real                rvals(1))
      external        nf_get_att_real

      integer         nf_put_att_double
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          double              dvals(1))
      external        nf_put_att_double

      integer         nf_get_att_double
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          double              dvals(1))
      external        nf_get_att_double

!
! general variable routines:
!

      integer         nf_def_var
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             datatype,
!                          integer             ndims,
!                          integer             dimids(1),
!                          integer             varid)
      external        nf_def_var

      integer         nf_inq_var
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             datatype,
!                          integer             ndims,
!                          integer             dimids(1),
!                          integer             natts)
      external        nf_inq_var

      integer         nf_inq_varid
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             varid)
      external        nf_inq_varid

      integer         nf_inq_varname
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name)
      external        nf_inq_varname

      integer         nf_inq_vartype
!                         (integer             ncid,
!                          integer             varid,
!                          integer             xtype)
      external        nf_inq_vartype

      integer         nf_inq_varndims
!                         (integer             ncid,
!                          integer             varid,
!                          integer             ndims)
      external        nf_inq_varndims

      integer         nf_inq_vardimid
!                         (integer             ncid,
!                          integer             varid,
!                          integer             dimids(1))
      external        nf_inq_vardimid

      integer         nf_inq_varnatts
!                         (integer             ncid,
!                          integer             varid,
!                          integer             natts)
      external        nf_inq_varnatts

      integer         nf_rename_var
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name)
      external        nf_rename_var

      integer         nf_copy_var
!                         (integer             ncid_in,
!                          integer             varid,
!                          integer             ncid_out)
      external        nf_copy_var

!
! entire variable put/get routines:
!

      integer         nf_put_var_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        text)
      external        nf_put_var_text

      integer         nf_get_var_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        text)
      external        nf_get_var_text

      integer         nf_put_var_int1
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int1_t           i1vals(1))
      external        nf_put_var_int1

      integer         nf_get_var_int1
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int1_t           i1vals(1))
      external        nf_get_var_int1

      integer         nf_put_var_int2
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int2_t           i2vals(1))
      external        nf_put_var_int2

      integer         nf_get_var_int2
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int2_t           i2vals(1))
      external        nf_get_var_int2

      integer         nf_put_var_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             ivals(1))
      external        nf_put_var_int

      integer         nf_get_var_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             ivals(1))
      external        nf_get_var_int

      integer         nf_put_var_real
!                         (integer             ncid,
!                          integer             varid,
!                          real                rvals(1))
      external        nf_put_var_real

      integer         nf_get_var_real
!                         (integer             ncid,
!                          integer             varid,
!                          real                rvals(1))
      external        nf_get_var_real

      integer         nf_put_var_double
!                         (integer             ncid,
!                          integer             varid,
!                          doubleprecision     dvals(1))
      external        nf_put_var_double

      integer         nf_get_var_double
!                         (integer             ncid,
!                          integer             varid,
!                          doubleprecision     dvals(1))
      external        nf_get_var_double

!
! single variable put/get routines:
!

      integer         nf_put_var1_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          character*1         text)
      external        nf_put_var1_text

      integer         nf_get_var1_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          character*1         text)
      external        nf_get_var1_text

      integer         nf_put_var1_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int1_t           i1val)
      external        nf_put_var1_int1

      integer         nf_get_var1_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int1_t           i1val)
      external        nf_get_var1_int1

      integer         nf_put_var1_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int2_t           i2val)
      external        nf_put_var1_int2

      integer         nf_get_var1_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int2_t           i2val)
      external        nf_get_var1_int2

      integer         nf_put_var1_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          integer             ival)
      external        nf_put_var1_int

      integer         nf_get_var1_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          integer             ival)
      external        nf_get_var1_int

      integer         nf_put_var1_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          real                rval)
      external        nf_put_var1_real

      integer         nf_get_var1_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          real                rval)
      external        nf_get_var1_real

      integer         nf_put_var1_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          doubleprecision     dval)
      external        nf_put_var1_double

      integer         nf_get_var1_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          doubleprecision     dval)
      external        nf_get_var1_double

!
! variable array put/get routines:
!

      integer         nf_put_vara_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          character(*)        text)
      external        nf_put_vara_text

      integer         nf_get_vara_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          character(*)        text)
      external        nf_get_vara_text

      integer         nf_put_vara_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int1_t           i1vals(1))
      external        nf_put_vara_int1

      integer         nf_get_vara_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int1_t           i1vals(1))
      external        nf_get_vara_int1

      integer         nf_put_vara_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int2_t           i2vals(1))
      external        nf_put_vara_int2

      integer         nf_get_vara_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int2_t           i2vals(1))
      external        nf_get_vara_int2

      integer         nf_put_vara_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             ivals(1))
      external        nf_put_vara_int

      integer         nf_get_vara_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             ivals(1))
      external        nf_get_vara_int

      integer         nf_put_vara_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          real                rvals(1))
      external        nf_put_vara_real

      integer         nf_get_vara_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          real                rvals(1))
      external        nf_get_vara_real

      integer         nf_put_vara_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          doubleprecision     dvals(1))
      external        nf_put_vara_double

      integer         nf_get_vara_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          doubleprecision     dvals(1))
      external        nf_get_vara_double

!
! strided variable put/get routines:
!

      integer         nf_put_vars_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          character(*)        text)
      external        nf_put_vars_text

      integer         nf_get_vars_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          character(*)        text)
      external        nf_get_vars_text

      integer         nf_put_vars_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int1_t           i1vals(1))
      external        nf_put_vars_int1

      integer         nf_get_vars_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int1_t           i1vals(1))
      external        nf_get_vars_int1

      integer         nf_put_vars_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int2_t           i2vals(1))
      external        nf_put_vars_int2

      integer         nf_get_vars_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int2_t           i2vals(1))
      external        nf_get_vars_int2

      integer         nf_put_vars_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             ivals(1))
      external        nf_put_vars_int

      integer         nf_get_vars_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             ivals(1))
      external        nf_get_vars_int

      integer         nf_put_vars_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          real                rvals(1))
      external        nf_put_vars_real

      integer         nf_get_vars_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          real                rvals(1))
      external        nf_get_vars_real

      integer         nf_put_vars_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          doubleprecision     dvals(1))
      external        nf_put_vars_double

      integer         nf_get_vars_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          doubleprecision     dvals(1))
      external        nf_get_vars_double

!
! mapped variable put/get routines:
!

      integer         nf_put_varm_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          character(*)        text)
      external        nf_put_varm_text

      integer         nf_get_varm_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          character(*)        text)
      external        nf_get_varm_text

      integer         nf_put_varm_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int1_t           i1vals(1))
      external        nf_put_varm_int1

      integer         nf_get_varm_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int1_t           i1vals(1))
      external        nf_get_varm_int1

      integer         nf_put_varm_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int2_t           i2vals(1))
      external        nf_put_varm_int2

      integer         nf_get_varm_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int2_t           i2vals(1))
      external        nf_get_varm_int2

      integer         nf_put_varm_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          integer             ivals(1))
      external        nf_put_varm_int

      integer         nf_get_varm_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          integer             ivals(1))
      external        nf_get_varm_int

      integer         nf_put_varm_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          real                rvals(1))
      external        nf_put_varm_real

      integer         nf_get_varm_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          real                rvals(1))
      external        nf_get_varm_real

      integer         nf_put_varm_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          doubleprecision     dvals(1))
      external        nf_put_varm_double

      integer         nf_get_varm_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          doubleprecision     dvals(1))
      external        nf_get_varm_double


!     NetCDF-4.
!     This is part of netCDF-4. Copyright 2006, UCAR, See COPYRIGHT
!     file for distribution information.

!     Netcdf version 4 fortran interface.

!     $Id: netcdf4.inc,v 1.28 2010/05/25 13:53:02 ed Exp $

!     New netCDF-4 types.
      integer nf_ubyte
      integer nf_ushort
      integer nf_uint
      integer nf_int64
      integer nf_uint64
      integer nf_string
      integer nf_vlen
      integer nf_opaque
      integer nf_enum
      integer nf_compound

      parameter (nf_ubyte = 7)
      parameter (nf_ushort = 8)
      parameter (nf_uint = 9)
      parameter (nf_int64 = 10)
      parameter (nf_uint64 = 11)
      parameter (nf_string = 12)
      parameter (nf_vlen = 13)
      parameter (nf_opaque = 14)
      parameter (nf_enum = 15)
      parameter (nf_compound = 16)

!     New netCDF-4 fill values.
      integer           nf_fill_ubyte
      integer           nf_fill_ushort
!      real              nf_fill_uint
!      real              nf_fill_int64
!      real              nf_fill_uint64
      parameter (nf_fill_ubyte = 255)
      parameter (nf_fill_ushort = 65535)

!     New constants.
      integer nf_format_netcdf4
      parameter (nf_format_netcdf4 = 3)

      integer nf_format_netcdf4_classic
      parameter (nf_format_netcdf4_classic = 4)

      integer nf_netcdf4
      parameter (nf_netcdf4 = 4096)

      integer nf_classic_model
      parameter (nf_classic_model = 256)

      integer nf_chunk_seq
      parameter (nf_chunk_seq = 0)
      integer nf_chunk_sub
      parameter (nf_chunk_sub = 1)
      integer nf_chunk_sizes
      parameter (nf_chunk_sizes = 2)

      integer nf_endian_native
      parameter (nf_endian_native = 0)
      integer nf_endian_little
      parameter (nf_endian_little = 1)
      integer nf_endian_big
      parameter (nf_endian_big = 2)

!     For NF_DEF_VAR_CHUNKING
      integer nf_chunked
      parameter (nf_chunked = 0)
      integer nf_contiguous
      parameter (nf_contiguous = 1)

!     For NF_DEF_VAR_FLETCHER32
      integer nf_nochecksum
      parameter (nf_nochecksum = 0)
      integer nf_fletcher32
      parameter (nf_fletcher32 = 1)

!     For NF_DEF_VAR_DEFLATE
      integer nf_noshuffle
      parameter (nf_noshuffle = 0)
      integer nf_shuffle
      parameter (nf_shuffle = 1)

!     For NF_DEF_VAR_SZIP
      integer nf_szip_ec_option_mask
      parameter (nf_szip_ec_option_mask = 4)
      integer nf_szip_nn_option_mask
      parameter (nf_szip_nn_option_mask = 32)

!     For parallel I/O.
      integer nf_mpiio      
      parameter (nf_mpiio = 8192)
      integer nf_mpiposix
      parameter (nf_mpiposix = 16384)
      integer nf_pnetcdf
      parameter (nf_pnetcdf = 32768)

!     For NF_VAR_PAR_ACCESS.
      integer nf_independent
      parameter (nf_independent = 0)
      integer nf_collective
      parameter (nf_collective = 1)

!     New error codes.
      integer nf_ehdferr        ! Error at HDF5 layer. 
      parameter (nf_ehdferr = -101)
      integer nf_ecantread      ! Can't read. 
      parameter (nf_ecantread = -102)
      integer nf_ecantwrite     ! Can't write. 
      parameter (nf_ecantwrite = -103)
      integer nf_ecantcreate    ! Can't create. 
      parameter (nf_ecantcreate = -104)
      integer nf_efilemeta      ! Problem with file metadata. 
      parameter (nf_efilemeta = -105)
      integer nf_edimmeta       ! Problem with dimension metadata. 
      parameter (nf_edimmeta = -106)
      integer nf_eattmeta       ! Problem with attribute metadata. 
      parameter (nf_eattmeta = -107)
      integer nf_evarmeta       ! Problem with variable metadata. 
      parameter (nf_evarmeta = -108)
      integer nf_enocompound    ! Not a compound type. 
      parameter (nf_enocompound = -109)
      integer nf_eattexists     ! Attribute already exists. 
      parameter (nf_eattexists = -110)
      integer nf_enotnc4        ! Attempting netcdf-4 operation on netcdf-3 file.   
      parameter (nf_enotnc4 = -111)
      integer nf_estrictnc3     ! Attempting netcdf-4 operation on strict nc3 netcdf-4 file.   
      parameter (nf_estrictnc3 = -112)
      integer nf_enotnc3        ! Attempting netcdf-3 operation on netcdf-4 file.   
      parameter (nf_enotnc3 = -113)
      integer nf_enopar         ! Parallel operation on file opened for non-parallel access.   
      parameter (nf_enopar = -114)
      integer nf_eparinit       ! Error initializing for parallel access.   
      parameter (nf_eparinit = -115)
      integer nf_ebadgrpid      ! Bad group ID.   
      parameter (nf_ebadgrpid = -116)
      integer nf_ebadtypid      ! Bad type ID.   
      parameter (nf_ebadtypid = -117)
      integer nf_etypdefined    ! Type has already been defined and may not be edited. 
      parameter (nf_etypdefined = -118)
      integer nf_ebadfield      ! Bad field ID.   
      parameter (nf_ebadfield = -119)
      integer nf_ebadclass      ! Bad class.   
      parameter (nf_ebadclass = -120)
      integer nf_emaptype       ! Mapped access for atomic types only.   
      parameter (nf_emaptype = -121)
      integer nf_elatefill      ! Attempt to define fill value when data already exists. 
      parameter (nf_elatefill = -122)
      integer nf_elatedef       ! Attempt to define var properties, like deflate, after enddef. 
      parameter (nf_elatedef = -123)
      integer nf_edimscale      ! Probem with HDF5 dimscales. 
      parameter (nf_edimscale = -124)
      integer nf_enogrp       ! No group found.
      parameter (nf_enogrp = -125)


!     New functions.

!     Parallel I/O.
      integer nf_create_par
      external nf_create_par

      integer nf_open_par
      external nf_open_par

      integer nf_var_par_access
      external nf_var_par_access

!     Functions to handle groups.
      integer nf_inq_ncid
      external nf_inq_ncid

      integer nf_inq_grps
      external nf_inq_grps

      integer nf_inq_grpname
      external nf_inq_grpname

      integer nf_inq_grpname_full
      external nf_inq_grpname_full

      integer nf_inq_grpname_len
      external nf_inq_grpname_len

      integer nf_inq_grp_parent
      external nf_inq_grp_parent

      integer nf_inq_grp_ncid
      external nf_inq_grp_ncid

      integer nf_inq_grp_full_ncid
      external nf_inq_grp_full_ncid

      integer nf_inq_varids
      external nf_inq_varids

      integer nf_inq_dimids
      external nf_inq_dimids

      integer nf_def_grp
      external nf_def_grp

!     New rename grp function

      integer nf_rename_grp
      external nf_rename_grp

!     New options for netCDF variables.
      integer nf_def_var_deflate
      external nf_def_var_deflate

      integer nf_inq_var_deflate
      external nf_inq_var_deflate

      integer nf_def_var_fletcher32
      external nf_def_var_fletcher32

      integer nf_inq_var_fletcher32
      external nf_inq_var_fletcher32

      integer nf_def_var_chunking
      external nf_def_var_chunking

      integer nf_inq_var_chunking
      external nf_inq_var_chunking

      integer nf_def_var_fill
      external nf_def_var_fill

      integer nf_inq_var_fill
      external nf_inq_var_fill

      integer nf_def_var_endian
      external nf_def_var_endian

      integer nf_inq_var_endian
      external nf_inq_var_endian

!     User defined types.
      integer nf_inq_typeids
      external nf_inq_typeids

      integer nf_inq_typeid
      external nf_inq_typeid

      integer nf_inq_type
      external nf_inq_type

      integer nf_inq_user_type
      external nf_inq_user_type

!     User defined types - compound types.
      integer nf_def_compound
      external nf_def_compound

      integer nf_insert_compound
      external nf_insert_compound

      integer nf_insert_array_compound
      external nf_insert_array_compound

      integer nf_inq_compound
      external nf_inq_compound

      integer nf_inq_compound_name
      external nf_inq_compound_name

      integer nf_inq_compound_size
      external nf_inq_compound_size

      integer nf_inq_compound_nfields
      external nf_inq_compound_nfields

      integer nf_inq_compound_field
      external nf_inq_compound_field

      integer nf_inq_compound_fieldname
      external nf_inq_compound_fieldname

      integer nf_inq_compound_fieldindex
      external nf_inq_compound_fieldindex

      integer nf_inq_compound_fieldoffset
      external nf_inq_compound_fieldoffset

      integer nf_inq_compound_fieldtype
      external nf_inq_compound_fieldtype

      integer nf_inq_compound_fieldndims
      external nf_inq_compound_fieldndims

      integer nf_inq_compound_fielddim_sizes
      external nf_inq_compound_fielddim_sizes

!     User defined types - variable length arrays.
      integer nf_def_vlen
      external nf_def_vlen

      integer nf_inq_vlen
      external nf_inq_vlen

      integer nf_free_vlen
      external nf_free_vlen

!     User defined types - enums.
      integer nf_def_enum
      external nf_def_enum

      integer nf_insert_enum
      external nf_insert_enum

      integer nf_inq_enum
      external nf_inq_enum

      integer nf_inq_enum_member
      external nf_inq_enum_member

      integer nf_inq_enum_ident
      external nf_inq_enum_ident

!     User defined types - opaque.
      integer nf_def_opaque
      external nf_def_opaque

      integer nf_inq_opaque
      external nf_inq_opaque

!     Write and read attributes of any type, including user defined
!     types.
      integer nf_put_att
      external nf_put_att
      integer nf_get_att
      external nf_get_att

!     Write and read variables of any type, including user defined
!     types.
      integer nf_put_var
      external nf_put_var
      integer nf_put_var1
      external nf_put_var1
      integer nf_put_vara
      external nf_put_vara
      integer nf_put_vars
      external nf_put_vars
      integer nf_get_var
      external nf_get_var
      integer nf_get_var1
      external nf_get_var1
      integer nf_get_vara
      external nf_get_vara
      integer nf_get_vars
      external nf_get_vars

!     64-bit int functions.
      integer nf_put_var1_int64
      external nf_put_var1_int64
      integer nf_put_vara_int64
      external nf_put_vara_int64
      integer nf_put_vars_int64
      external nf_put_vars_int64
      integer nf_put_varm_int64
      external nf_put_varm_int64
      integer nf_put_var_int64
      external nf_put_var_int64
      integer nf_get_var1_int64
      external nf_get_var1_int64
      integer nf_get_vara_int64
      external nf_get_vara_int64
      integer nf_get_vars_int64
      external nf_get_vars_int64
      integer nf_get_varm_int64
      external nf_get_varm_int64
      integer nf_get_var_int64
      external nf_get_var_int64

!     For helping F77 users with VLENs.
      integer nf_get_vlen_element
      external nf_get_vlen_element
      integer nf_put_vlen_element
      external nf_put_vlen_element

!     For dealing with file level chunk cache.
      integer nf_set_chunk_cache
      external nf_set_chunk_cache
      integer nf_get_chunk_cache
      external nf_get_chunk_cache

!     For dealing with per variable chunk cache.
      integer nf_set_var_chunk_cache
      external nf_set_var_chunk_cache
      integer nf_get_var_chunk_cache
      external nf_get_var_chunk_cache

!     NetCDF-2.
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
! begin netcdf 2.4 backward compatibility:
!

!      
! functions in the fortran interface
!
      integer nccre
      integer ncopn
      integer ncddef
      integer ncdid
      integer ncvdef
      integer ncvid
      integer nctlen
      integer ncsfil

      external nccre
      external ncopn
      external ncddef
      external ncdid
      external ncvdef
      external ncvid
      external nctlen
      external ncsfil


      integer ncrdwr
      integer nccreat
      integer ncexcl
      integer ncindef
      integer ncnsync
      integer nchsync
      integer ncndirty
      integer nchdirty
      integer nclink
      integer ncnowrit
      integer ncwrite
      integer ncclob
      integer ncnoclob
      integer ncglobal
      integer ncfill
      integer ncnofill
      integer maxncop
      integer maxncdim
      integer maxncatt
      integer maxncvar
      integer maxncnam
      integer maxvdims
      integer ncnoerr
      integer ncebadid
      integer ncenfile
      integer nceexist
      integer nceinval
      integer nceperm
      integer ncenotin
      integer nceindef
      integer ncecoord
      integer ncemaxds
      integer ncename
      integer ncenoatt
      integer ncemaxat
      integer ncebadty
      integer ncebadd
      integer ncests
      integer nceunlim
      integer ncemaxvs
      integer ncenotvr
      integer nceglob
      integer ncenotnc
      integer ncfoobar
      integer ncsyserr
      integer ncfatal
      integer ncverbos
      integer ncentool


!
! netcdf data types:
!
      integer ncbyte
      integer ncchar
      integer ncshort
      integer nclong
      integer ncfloat
      integer ncdouble

      parameter(ncbyte = 1)
      parameter(ncchar = 2)
      parameter(ncshort = 3)
      parameter(nclong = 4)
      parameter(ncfloat = 5)
      parameter(ncdouble = 6)

!     
!     masks for the struct nc flag field; passed in as 'mode' arg to
!     nccreate and ncopen.
!     

!     read/write, 0 => readonly 
      parameter(ncrdwr = 1)
!     in create phase, cleared by ncendef 
      parameter(nccreat = 2)
!     on create destroy existing file 
      parameter(ncexcl = 4)
!     in define mode, cleared by ncendef 
      parameter(ncindef = 8)
!     synchronise numrecs on change (x'10')
      parameter(ncnsync = 16)
!     synchronise whole header on change (x'20')
      parameter(nchsync = 32)
!     numrecs has changed (x'40')
      parameter(ncndirty = 64)  
!     header info has changed (x'80')
      parameter(nchdirty = 128)
!     prefill vars on endef and increase of record, the default behavior
      parameter(ncfill = 0)
!     do not fill vars on endef and increase of record (x'100')
      parameter(ncnofill = 256)
!     isa link (x'8000')
      parameter(nclink = 32768)

!     
!     'mode' arguments for nccreate and ncopen
!     
      parameter(ncnowrit = 0)
      parameter(ncwrite = ncrdwr)
      parameter(ncclob = nf_clobber)
      parameter(ncnoclob = nf_noclobber)

!     
!     'size' argument to ncdimdef for an unlimited dimension
!     
      integer ncunlim
      parameter(ncunlim = 0)

!     
!     attribute id to put/get a global attribute
!     
      parameter(ncglobal  = 0)

!     
!     advisory maximums:
!     
      parameter(maxncop = 64)
      parameter(maxncdim = 1024)
      parameter(maxncatt = 8192)
      parameter(maxncvar = 8192)
!     not enforced 
      parameter(maxncnam = 256)
      parameter(maxvdims = maxncdim)

!     
!     global netcdf error status variable
!     initialized in error.c
!     

!     no error 
      parameter(ncnoerr = nf_noerr)
!     not a netcdf id 
      parameter(ncebadid = nf_ebadid)
!     too many netcdfs open 
      parameter(ncenfile = -31)   ! nc_syserr
!     netcdf file exists && ncnoclob
      parameter(nceexist = nf_eexist)
!     invalid argument 
      parameter(nceinval = nf_einval)
!     write to read only 
      parameter(nceperm = nf_eperm)
!     operation not allowed in data mode 
      parameter(ncenotin = nf_enotindefine )   
!     operation not allowed in define mode 
      parameter(nceindef = nf_eindefine)   
!     coordinates out of domain 
      parameter(ncecoord = nf_einvalcoords)
!     maxncdims exceeded 
      parameter(ncemaxds = nf_emaxdims)
!     string match to name in use 
      parameter(ncename = nf_enameinuse)   
!     attribute not found 
      parameter(ncenoatt = nf_enotatt)
!     maxncattrs exceeded 
      parameter(ncemaxat = nf_emaxatts)
!     not a netcdf data type 
      parameter(ncebadty = nf_ebadtype)
!     invalid dimension id 
      parameter(ncebadd = nf_ebaddim)
!     ncunlimited in the wrong index 
      parameter(nceunlim = nf_eunlimpos)
!     maxncvars exceeded 
      parameter(ncemaxvs = nf_emaxvars)
!     variable not found 
      parameter(ncenotvr = nf_enotvar)
!     action prohibited on ncglobal varid 
      parameter(nceglob = nf_eglobal)
!     not a netcdf file 
      parameter(ncenotnc = nf_enotnc)
      parameter(ncests = nf_ests)
      parameter (ncentool = nf_emaxname) 
      parameter(ncfoobar = 32)
      parameter(ncsyserr = -31)

!     
!     global options variable. used to determine behavior of error handler.
!     initialized in lerror.c
!     
      parameter(ncfatal = 1)
      parameter(ncverbos = 2)

!
!     default fill values.  these must be the same as in the c interface.
!
      integer filbyte
      integer filchar
      integer filshort
      integer fillong
      real filfloat
      doubleprecision fildoub

      parameter (filbyte = -127)
      parameter (filchar = 0)
      parameter (filshort = -32767)
      parameter (fillong = -2147483647)
      parameter (filfloat = 9.9692099683868690e+36)
      parameter (fildoub = 9.9692099683868690e+36)

    character(len=*),                         intent(in) :: outdir
    character(len=*),                         intent(in) :: version
    integer,                                  intent(in) :: igrid
    integer,                                  intent(in) :: output_timestep
    character(len=*),                         intent(in) :: llanduse
    integer,                                  intent(in) :: split_output_count
    character,                                intent(in) :: hgrid
    integer,                                  intent(in) :: ixfull
    integer,                                  intent(in) :: jxfull
    integer,                                  intent(in) :: ixpar
    integer,                                  intent(in) :: jxpar
    integer,                                  intent(in) :: xstartpar
    integer,                                  intent(in) :: ystartpar
    integer,                                  intent(in) :: iswater
    integer,                                  intent(in) :: mapproj
    real,                                     intent(in) :: lat1
    real,                                     intent(in) :: lon1
    real,                                     intent(in) :: dx
    real,                                     intent(in) :: dy
    real,                                     intent(in) :: truelat1
    real,                                     intent(in) :: truelat2
    real,                                     intent(in) :: cen_lon
    integer,                                  intent(in) :: nsoil
    integer,                                  intent(in) :: nsnow
    real,             dimension(nsoil),       intent(in) :: sldpth
    character(len=19),                        intent(in) :: startdate
    character(len=19),                        intent(in) :: date
    integer,                                  intent(in) :: spinup_loop
    integer,                                  intent(in) :: spinup_loops
    integer,          dimension(ixpar,jxpar), intent(in) :: vegtyp
    integer,          dimension(ixpar,jxpar), intent(in) :: soltyp

    integer :: ncid

    integer :: dimid_ix, dimid_jx, dimid_times, dimid_datelen, varid, n
    integer :: dimid_dum, dimid_layers, dimid_snow_layers
    integer :: iret
    character(len=256) :: output_flnm
    character(len=19)  :: date19

    integer :: ierr

    if (output_count_remember == 0) then
       ! If this is a new output file:
       !   We have to create a new file, do dimension initializations, and write global attributes to the file.
       !   Then we get out of define mode.
       if (mod(output_timestep,3600) == 0) then
          write(output_flnm, '(A,"/",A10,".LDASOUT_DOMAIN",I1)') outdir, date(1:4)//date(6:7)//date(9:10)//date(12:13), igrid
       elseif (mod(output_timestep,60) == 0) then
          write(output_flnm, '(A,"/",A12,".LDASOUT_DOMAIN",I1)') outdir, date(1:4)//date(6:7)//date(9:10)//date(12:13)//date(15:16), igrid
       else
          write(output_flnm, '(A,"/",A14,".LDASOUT_DOMAIN",I1)') outdir, date(1:4)//date(6:7)//date(9:10)//date(12:13)//date(15:16)//date(18:19), igrid
       endif
       if(spinup_loops > 0) then
         write(output_flnm, '(A,".loop",i4.4)') trim(output_flnm), spinup_loop
       end if
       iret = nf90_create(trim(output_flnm), NF90_CLOBBER, ncid)
       call error_handler(iret, failure="Problem nf90_create for "//trim(output_flnm))

       ncid_remember = ncid
       define_mode_remember = .TRUE.

       iret = nf90_def_dim(ncid, "Time", NF90_UNLIMITED, dimid_times)
       iret = nf90_def_dim(ncid, "DateStrLen", 19, dimid_datelen)
       ! Dimensions reflect the full size of the subwindow (not the strip known by this particular process).
       iret = nf90_def_dim(ncid, "west_east", ixfull, dimid_ix)
       iret = nf90_def_dim(ncid, "south_north", jxfull, dimid_jx)
       iret = nf90_def_dim(ncid, "west_east_stag", ixfull+1, dimid_dum)
       iret = nf90_def_dim(ncid, "south_north_stag", jxfull+1, dimid_dum)
       iret = nf90_def_dim(ncid, "soil_layers_stag", nsoil, dimid_layers)
       iret = nf90_def_dim(ncid, "snow_layers", nsnow, dimid_snow_layers)

       iret = nf90_put_att(ncid, NF90_GLOBAL, "TITLE", "OUTPUT FROM HRLDAS "//version)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "missing_value", -1.E33)

       ! TODO:  Add Grid information   (should look more-or-less like wrfout files)
       ! TODO:  Add Units information  (should look more-or-less like wrfout files)

       date19(1:19) = "0000-00-00_00:00:00"
       date19(1:len_trim(startdate)) = startdate

       iret = nf90_put_att(ncid, NF90_GLOBAL, "START_DATE", date19)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "MAP_PROJ", mapproj)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "LAT1", lat1)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "LON1", lon1)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "DX", dx)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "DY", dy)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "TRUELAT1", truelat1)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "TRUELAT2", truelat2)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "STAND_LON", cen_lon)
       iret = nf90_put_att(ncid, NF90_GLOBAL, "MMINLU", llanduse)

!
! Done with dimensions and global attributes.
! Now define and describe our "Times" variable.
!

       iret = nf90_def_var(ncid,  "Times",  NF90_CHAR, (/dimid_datelen,dimid_times/), varid)
       call error_handler(iret, failure="Problem nf90_def_var for "//trim(output_flnm))

       iret = nf90_enddef(ncid)
       call error_handler(iret, failure="Problem nf90_enddef")
       define_mode_remember = .FALSE.

    endif
    xstartpar_remember = xstartpar
    dimid_ix_remember = dimid_ix
    dimid_jx_remember = dimid_jx
    dimid_times_remember = dimid_times
    dimid_layers_remember = dimid_layers
    dimid_snow_layers_remember = dimid_snow_layers
    iswater_remember = iswater

    allocate(vegtyp_remember(ixpar,jxpar))
    vegtyp_remember = vegtyp

!
! While we're here, put the data for the "Times" variable to the NetCDF file.
!

    date19(1:19) = "0000-00-00_00:00:00"
    date19(1:len_trim(date)) = date
    iret = nf90_inq_varid(ncid_remember, "Times", varid)
    call error_handler(iret, "OUTPUT_HRLDAS:  Problem inquiring on 'Times'")

    iret = nf90_put_var(ncid_remember, varid, date, (/1,output_count_remember+1/), (/19,1/))
    call error_handler(iret, "OUTPUT_HRLDAS:  Problem writing variable 'Times'")

  end subroutine prepare_output_file_seq

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine set_output_define_mode(imode)
    implicit none
    integer, intent(in) :: imode
    integer :: ierr


    if (imode == 1) then
       ! We need to define things only with a new file, i.e., only when output_count_remember == 0
       if (output_count_remember > 0) return
       ierr = nf90_redef(ncid_remember)
       call error_handler(ierr, failure="Problem nf90_redef")
       define_mode_remember = .TRUE.
    else
       if (define_mode_remember) then
          ierr = nf90_enddef(ncid_remember)
          call error_handler(ierr, failure="Problem nf90_enddef")
          define_mode_remember = .FALSE.
       endif
    endif

  end subroutine set_output_define_mode

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine finalize_output_file(split_output_count,itime)
    implicit none
    integer, intent(in)  :: split_output_count
    integer, intent(in)  :: itime
    integer :: ierr


    output_count_remember = output_count_remember + 1
    if (output_count_remember == split_output_count) then
       output_count_remember = 0 
       ierr = nf90_close(ncid_remember)
       call error_handler(ierr, failure="Problem nf90_close for output file")
    elseif (split_output_count > 1 .and. itime == 0) then  ! treat first time different
       output_count_remember = 0 
       ierr = nf90_close(ncid_remember)
       call error_handler(ierr, failure="Problem nf90_close for output file")
    else
       ierr = nf90_sync(ncid_remember)
       call error_handler(ierr, failure="Problem nf90_sync for output file")
    endif

    deallocate(vegtyp_remember)

  end subroutine finalize_output_file

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine add_to_output_2d_float ( array, name, description, units )
    implicit none
    real, dimension(:,:), intent(in) :: array
    character(len=*), intent(in) :: name, description, units
    integer :: ixpar, jxpar

    if (define_mode_remember) then
       call make_var_att_2d ( ncid_remember , dimid_ix_remember , dimid_jx_remember , dimid_times_remember , &
            NF90_FLOAT , trim(name) , trim(description) , trim(units) )
    else 
       ixpar = size(array,1)
       jxpar = size(array,2)
       call put_var_2d (ncid_remember , output_count_remember+1 , vegtyp_remember , iswater_remember , &
            ixpar , jxpar , xstartpar_remember , trim(name) , array, .false. )
    endif
  end subroutine add_to_output_2d_float

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine add_to_output_2d_integer ( array, name, description, units )
    implicit none
    integer, dimension(:,:), intent(in) :: array
    character(len=*), intent(in) :: name, description, units
    integer :: ixpar, jxpar

    if (define_mode_remember) then
       call make_var_att_2d ( ncid_remember , dimid_ix_remember , dimid_jx_remember , dimid_times_remember , &
            NF90_INT , trim(name) , trim(description) , trim(units) )
    else
       ixpar = size(array,1)
       jxpar = size(array,2)
       call put_var_int (ncid_remember , output_count_remember+1 , vegtyp_remember , iswater_remember , &
            ixpar , jxpar , xstartpar_remember , trim(name) , array )
    endif
  end subroutine add_to_output_2d_integer

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine add_to_output_3d ( array, name, description, units, snow_or_soil )
    implicit none
    real, dimension(:,:,:), intent(in) :: array
    character(len=*), intent(in) :: name, description, units
    character(len=4), intent(in) :: snow_or_soil
    integer :: ixpar, jxpar, kxpar
    integer :: zdimid

    if (define_mode_remember) then
       if (snow_or_soil == "SOIL") then
          zdimid = dimid_layers_remember
       elseif (snow_or_soil == "SNOW") then
          zdimid = dimid_snow_layers_remember
       else
          write(*,'("SNOW_OR_SOIL unrecognized: ", A)') adjustl(trim(snow_or_soil))
          stop "SNOW_OR_SOIL"
       endif
       call make_var_att_3d ( ncid_remember , dimid_ix_remember , dimid_jx_remember , dimid_times_remember , &
            NF90_FLOAT , zdimid, trim(name) , trim(description) , trim(units) )
    else 

       ixpar = size(array,1)
       kxpar = size(array,2)
       jxpar = size(array,3)

       call put_var_3d (ncid_remember , output_count_remember+1 , vegtyp_remember , iswater_remember , &
            ixpar , jxpar , xstartpar_remember , kxpar, trim(name) , array )
    endif
  end subroutine add_to_output_3d

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine make_var_att_2d(ncid, dimid_ix, dimid_jx, dimid_times, itype, varname, vardesc, varunits)
    implicit none
    integer,          intent(in) :: ncid
    character(len=*), intent(in) :: varname
    character(len=*), intent(in) :: vardesc
    character(len=*), intent(in) :: varunits
    integer,          intent(in) :: dimid_ix
    integer,          intent(in) :: dimid_jx
    integer,          intent(in) :: dimid_times
    integer,          intent(in) :: itype
    integer :: iret
    integer :: varid

    iret = nf90_def_var(ncid,  varname,   itype, (/dimid_ix,dimid_jx,dimid_times/), varid)
    call error_handler(iret, "MAKE_VAR_ATT_2D: Failure defining variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "MemoryOrder", "XY ")
    call error_handler(iret, "MAKE_VAR_ATT_2D: Failure adding MemoryOrder attribute to variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "description", vardesc)
    call error_handler(iret, "MAKE_VAR_ATT_2D: Failure adding description attribute to variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "units", varunits)
    call error_handler(iret, "MAKE_VAR_ATT_2D: Failure adding units attribute '"//trim(varunits)//"' to variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "stagger", "-")
    call error_handler(iret, "MAKE_VAR_ATT_2D: Failure adding stagger attribute to variable "//trim(varname))

  end subroutine make_var_att_2d

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine make_var_att_3d(ncid, dimid_ix, dimid_jx, dimid_times, itype, dimid_layers, varname, vardesc, varunits)
    implicit none
    integer,          intent(in) :: ncid
    character(len=*), intent(in) :: varname
    character(len=*), intent(in) :: vardesc
    character(len=*), intent(in) :: varunits
    integer,          intent(in) :: dimid_ix
    integer,          intent(in) :: dimid_jx
    integer,          intent(in) :: dimid_times
    integer,          intent(in) :: dimid_layers
    integer,          intent(in) :: itype
    integer :: iret
    integer :: varid

    iret = nf90_def_var(ncid,  varname, itype, (/dimid_ix,dimid_layers,dimid_jx,dimid_times/), varid)
    call error_handler(iret, "MAKE_VAR_ATT_3D:  Failure defining variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "MemoryOrder", "XZY")
    call error_handler(iret, "MAKE_VAR_ATT_3D: Failure adding MemoryOrder attribute for variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "description", vardesc)
    call error_handler(iret, "MAKE_VAR_ATT_3D: Failure adding description attribute to variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "units", varunits)
    call error_handler(iret, "MAKE_VAR_ATT_3D: Failure adding units attribute '"//trim(varunits)//"' to variable "//trim(varname))

    iret = nf90_put_att(ncid, varid, "stagger", "Z")
    call error_handler(iret, "MAKE_VAR_ATT_3D: Failure adding stagger attribute to variable "//trim(varname))

  end subroutine make_var_att_3d

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine put_var_2d(ncid, output_count, vegtyp, iswater, ix, jx, xstart, varname, vardata, restart_flag)
    implicit none
    integer,                   intent(in) :: ncid
    integer,                   intent(in) :: output_count
    character(len=*),          intent(in) :: varname
    integer,                   intent(in) :: ix
    integer,                   intent(in) :: jx
    integer,                   intent(in) :: xstart
    integer, dimension(ix,jx), intent(in) :: vegtyp
    integer,                   intent(in) :: iswater
    real,    dimension(ix,jx), intent(in) :: vardata
    logical,                   intent(in) :: restart_flag

    real,    dimension(ix,jx)             :: xdum
    integer                               :: iret
    integer                               :: varid

    integer, dimension(3) :: nstart
    integer, dimension(3) :: ncount

    where (vegtyp == ISWATER .and. .not. restart_flag)
       xdum = -1.E33
    elsewhere
       xdum = vardata
    endwhere

    iret = nf90_inq_varid(ncid,  varname, varid)
    call error_handler(iret, "Subroutine PUT_VAR_2D:  Problem finding variable id for "//trim(varname)//".")

    nstart = (/ xstart ,  1 , output_count /)
    ncount = (/     ix , jx ,            1 /)

    iret = nf90_put_var(ncid, varid, xdum, start=nstart, count=ncount)
    call error_handler(iret, "Subroutine PUT_VAR_2D:  Problem putting variable "//trim(varname)//" to NetCDF file.")

  end subroutine put_var_2d

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine put_var_int(ncid, output_count, vegtyp, iswater, ix, jx, xstart, varname, vardata)
    implicit none
    integer,                                              intent(in) :: ncid
    integer,                                              intent(in) :: output_count
    character(len=*),                                     intent(in) :: varname
    integer,                                              intent(in) :: ix
    integer,                                              intent(in) :: jx
    integer,                                              intent(in) :: xstart
    integer,                                              intent(in) :: iswater
    integer, dimension(ix,jx),                            intent(in) :: vegtyp
    integer, dimension(ix,jx),                            intent(in) :: vardata

    integer                                                          :: iret
    integer                                                          :: varid

    integer, dimension(3)                                            :: nstart
    integer, dimension(3)                                            :: ncount

    nstart = (/ xstart ,  1 , output_count /)
    ncount = (/     ix , jx ,            1 /)

    iret = nf90_inq_varid(ncid,  varname, varid)
    call error_handler(iret, failure="Subroutine PUT_VAR_INT:  Problem finding variable id for variable: "//varname)

    iret = nf90_put_var(ncid, varid, vardata, nstart, ncount)
    call error_handler(iret, failure="Subroutine PUT_VAR_INT:  Problem putting variable '"//varname//"' to NetCDF file.")

  end subroutine put_var_int

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine put_var_3d(ncid, output_count, vegtyp, iswater, ix, jx, xstart, nsoil, varname, vardata)
    implicit none
    integer,                                                    intent(in) :: ncid
    integer,                                                    intent(in) :: output_count
    character(len=*),                                           intent(in) :: varname
    integer,                                                    intent(in) :: ix
    integer,                                                    intent(in) :: jx
    integer,                                                    intent(in) :: xstart
    integer,                                                    intent(in) :: nsoil
    integer,                                                    intent(in) :: iswater
    integer, dimension(ix, jx),                                 intent(in) :: vegtyp
    real,    dimension(ix, nsoil, jx),                          intent(in) :: vardata
    real,    dimension(ix, nsoil, jx)                                      :: xdum
    integer                                                                :: iret
    integer                                                                :: varid
    integer                                                                :: n
    integer, dimension(4)                                                  :: nstart
    integer, dimension(4)                                                  :: ncount

    nstart = (/ xstart ,  1 ,     1 , output_count /)
    ncount = (/     ix , nsoil , jx ,            1 /)

    xdum = vardata
    do n = 1, nsoil
       where (vegtyp(:,:) == ISWATER) xdum(:,n,:) = -1.E33
    enddo

    iret = nf90_inq_varid(ncid,  varname, varid)
    call error_handler(iret, "Subroutine PUT_VAR_3D:  Problem finding variable id for "//trim(varname)//".")

    iret = nf90_put_var(ncid, varid, xdum, start=nstart, count=ncount)
    call error_handler(iret, "Subroutine PUT_VAR_3D:  Problem putting variable "//trim(varname)//" to NetCDF file.")

  end subroutine put_var_3d

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------
  subroutine finalize_restart_file()
    implicit none

    !yw  deallocate(vegtyp_remember)
    if(allocated(vegtyp_remember)) deallocate(vegtyp_remember)
    restart_filename_remember = " "
    iswater_remember   = -999999
    xstartpar_remember = -999999
    
  end subroutine finalize_restart_file

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------


  subroutine prepare_restart_file_seq(outdir, version, igrid, llanduse, olddate, startdate,  &
       ixfull, jxfull, ixpar, jxpar, xstartpar, ystartpar,                                    &
       nsoil, nsnow, num_urban_layers, dx, dy, truelat1, truelat2, mapproj, lat1, lon1, cen_lon,                       &
       iswater, vegtyp)

    implicit none
!     NetCDF-3.
!
! netcdf version 3 fortran interface:
!

!
! external netcdf data types:
!
      integer nf_byte
      integer nf_int1
      integer nf_char
      integer nf_short
      integer nf_int2
      integer nf_int
      integer nf_float
      integer nf_real
      integer nf_double

      parameter (nf_byte = 1)
      parameter (nf_int1 = nf_byte)
      parameter (nf_char = 2)
      parameter (nf_short = 3)
      parameter (nf_int2 = nf_short)
      parameter (nf_int = 4)
      parameter (nf_float = 5)
      parameter (nf_real = nf_float)
      parameter (nf_double = 6)

!
! default fill values:
!
      integer           nf_fill_byte
      integer           nf_fill_int1
      integer           nf_fill_char
      integer           nf_fill_short
      integer           nf_fill_int2
      integer           nf_fill_int
      real              nf_fill_float
      real              nf_fill_real
      doubleprecision   nf_fill_double

      parameter (nf_fill_byte = -127)
      parameter (nf_fill_int1 = nf_fill_byte)
      parameter (nf_fill_char = 0)
      parameter (nf_fill_short = -32767)
      parameter (nf_fill_int2 = nf_fill_short)
      parameter (nf_fill_int = -2147483647)
      parameter (nf_fill_float = 9.9692099683868690e+36)
      parameter (nf_fill_real = nf_fill_float)
      parameter (nf_fill_double = 9.9692099683868690d+36)

!
! mode flags for opening and creating a netcdf dataset:
!
      integer nf_nowrite
      integer nf_write
      integer nf_clobber
      integer nf_noclobber
      integer nf_fill
      integer nf_nofill
      integer nf_lock
      integer nf_share
      integer nf_64bit_offset
      integer nf_sizehint_default
      integer nf_align_chunk
      integer nf_format_classic
      integer nf_format_64bit
      integer nf_diskless
      integer nf_mmap

      parameter (nf_nowrite = 0)
      parameter (nf_write = 1)
      parameter (nf_clobber = 0)
      parameter (nf_noclobber = 4)
      parameter (nf_fill = 0)
      parameter (nf_nofill = 256)
      parameter (nf_lock = 1024)
      parameter (nf_share = 2048)
      parameter (nf_64bit_offset = 512)
      parameter (nf_sizehint_default = 0)
      parameter (nf_align_chunk = -1)
      parameter (nf_format_classic = 1)
      parameter (nf_format_64bit = 2)
      parameter (nf_diskless = 8)
      parameter (nf_mmap = 16)

!
! size argument for defining an unlimited dimension:
!
      integer nf_unlimited
      parameter (nf_unlimited = 0)

!
! global attribute id:
!
      integer nf_global
      parameter (nf_global = 0)

!
! implementation limits:
!
      integer nf_max_dims
      integer nf_max_attrs
      integer nf_max_vars
      integer nf_max_name
      integer nf_max_var_dims

      parameter (nf_max_dims = 1024)
      parameter (nf_max_attrs = 8192)
      parameter (nf_max_vars = 8192)
      parameter (nf_max_name = 256)
      parameter (nf_max_var_dims = nf_max_dims)

!
! error codes:
!
      integer nf_noerr
      integer nf_ebadid
      integer nf_eexist
      integer nf_einval
      integer nf_eperm
      integer nf_enotindefine
      integer nf_eindefine
      integer nf_einvalcoords
      integer nf_emaxdims
      integer nf_enameinuse
      integer nf_enotatt
      integer nf_emaxatts
      integer nf_ebadtype
      integer nf_ebaddim
      integer nf_eunlimpos
      integer nf_emaxvars
      integer nf_enotvar
      integer nf_eglobal
      integer nf_enotnc
      integer nf_ests
      integer nf_emaxname
      integer nf_eunlimit
      integer nf_enorecvars
      integer nf_echar
      integer nf_eedge
      integer nf_estride
      integer nf_ebadname
      integer nf_erange
      integer nf_enomem
      integer nf_evarsize
      integer nf_edimsize
      integer nf_etrunc

      parameter (nf_noerr = 0)
      parameter (nf_ebadid = -33)
      parameter (nf_eexist = -35)
      parameter (nf_einval = -36)
      parameter (nf_eperm = -37)
      parameter (nf_enotindefine = -38)
      parameter (nf_eindefine = -39)
      parameter (nf_einvalcoords = -40)
      parameter (nf_emaxdims = -41)
      parameter (nf_enameinuse = -42)
      parameter (nf_enotatt = -43)
      parameter (nf_emaxatts = -44)
      parameter (nf_ebadtype = -45)
      parameter (nf_ebaddim = -46)
      parameter (nf_eunlimpos = -47)
      parameter (nf_emaxvars = -48)
      parameter (nf_enotvar = -49)
      parameter (nf_eglobal = -50)
      parameter (nf_enotnc = -51)
      parameter (nf_ests = -52)
      parameter (nf_emaxname = -53)
      parameter (nf_eunlimit = -54)
      parameter (nf_enorecvars = -55)
      parameter (nf_echar = -56)
      parameter (nf_eedge = -57)
      parameter (nf_estride = -58)
      parameter (nf_ebadname = -59)
      parameter (nf_erange = -60)
      parameter (nf_enomem = -61)
      parameter (nf_evarsize = -62)
      parameter (nf_edimsize = -63)
      parameter (nf_etrunc = -64)
!
! error handling modes:
!
      integer  nf_fatal
      integer nf_verbose

      parameter (nf_fatal = 1)
      parameter (nf_verbose = 2)

!
! miscellaneous routines:
!
      character*80   nf_inq_libvers
      external       nf_inq_libvers

      character*80   nf_strerror
!                         (integer             ncerr)
      external       nf_strerror

      logical        nf_issyserr
!                         (integer             ncerr)
      external       nf_issyserr

!
! control routines:
!
      integer         nf_inq_base_pe
!                         (integer             ncid,
!                          integer             pe)
      external        nf_inq_base_pe

      integer         nf_set_base_pe
!                         (integer             ncid,
!                          integer             pe)
      external        nf_set_base_pe

      integer         nf_create
!                         (character*(*)       path,
!                          integer             cmode,
!                          integer             ncid)
      external        nf_create

      integer         nf__create
!                         (character*(*)       path,
!                          integer             cmode,
!                          integer             initialsz,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__create

      integer         nf__create_mp
!                         (character*(*)       path,
!                          integer             cmode,
!                          integer             initialsz,
!                          integer             basepe,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__create_mp

      integer         nf_open
!                         (character*(*)       path,
!                          integer             mode,
!                          integer             ncid)
      external        nf_open

      integer         nf__open
!                         (character*(*)       path,
!                          integer             mode,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__open

      integer         nf__open_mp
!                         (character*(*)       path,
!                          integer             mode,
!                          integer             basepe,
!                          integer             chunksizehint,
!                          integer             ncid)
      external        nf__open_mp

      integer         nf_set_fill
!                         (integer             ncid,
!                          integer             fillmode,
!                          integer             old_mode)
      external        nf_set_fill

      integer         nf_set_default_format
!                          (integer             format,
!                          integer             old_format)
      external        nf_set_default_format

      integer         nf_redef
!                         (integer             ncid)
      external        nf_redef

      integer         nf_enddef
!                         (integer             ncid)
      external        nf_enddef

      integer         nf__enddef
!                         (integer             ncid,
!                          integer             h_minfree,
!                          integer             v_align,
!                          integer             v_minfree,
!                          integer             r_align)
      external        nf__enddef

      integer         nf_sync
!                         (integer             ncid)
      external        nf_sync

      integer         nf_abort
!                         (integer             ncid)
      external        nf_abort

      integer         nf_close
!                         (integer             ncid)
      external        nf_close

      integer         nf_delete
!                         (character*(*)       ncid)
      external        nf_delete

!
! general inquiry routines:
!

      integer         nf_inq
!                         (integer             ncid,
!                          integer             ndims,
!                          integer             nvars,
!                          integer             ngatts,
!                          integer             unlimdimid)
      external        nf_inq

! new inquire path

      integer nf_inq_path
      external nf_inq_path

      integer         nf_inq_ndims
!                         (integer             ncid,
!                          integer             ndims)
      external        nf_inq_ndims

      integer         nf_inq_nvars
!                         (integer             ncid,
!                          integer             nvars)
      external        nf_inq_nvars

      integer         nf_inq_natts
!                         (integer             ncid,
!                          integer             ngatts)
      external        nf_inq_natts

      integer         nf_inq_unlimdim
!                         (integer             ncid,
!                          integer             unlimdimid)
      external        nf_inq_unlimdim

      integer         nf_inq_format
!                         (integer             ncid,
!                          integer             format)
      external        nf_inq_format

!
! dimension routines:
!

      integer         nf_def_dim
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             len,
!                          integer             dimid)
      external        nf_def_dim

      integer         nf_inq_dimid
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             dimid)
      external        nf_inq_dimid

      integer         nf_inq_dim
!                         (integer             ncid,
!                          integer             dimid,
!                          character(*)        name,
!                          integer             len)
      external        nf_inq_dim

      integer         nf_inq_dimname
!                         (integer             ncid,
!                          integer             dimid,
!                          character(*)        name)
      external        nf_inq_dimname

      integer         nf_inq_dimlen
!                         (integer             ncid,
!                          integer             dimid,
!                          integer             len)
      external        nf_inq_dimlen

      integer         nf_rename_dim
!                         (integer             ncid,
!                          integer             dimid,
!                          character(*)        name)
      external        nf_rename_dim

!
! general attribute routines:
!

      integer         nf_inq_att
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len)
      external        nf_inq_att

      integer         nf_inq_attid
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             attnum)
      external        nf_inq_attid

      integer         nf_inq_atttype
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype)
      external        nf_inq_atttype

      integer         nf_inq_attlen
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             len)
      external        nf_inq_attlen

      integer         nf_inq_attname
!                         (integer             ncid,
!                          integer             varid,
!                          integer             attnum,
!                          character(*)        name)
      external        nf_inq_attname

      integer         nf_copy_att
!                         (integer             ncid_in,
!                          integer             varid_in,
!                          character(*)        name,
!                          integer             ncid_out,
!                          integer             varid_out)
      external        nf_copy_att

      integer         nf_rename_att
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        curname,
!                          character(*)        newname)
      external        nf_rename_att

      integer         nf_del_att
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name)
      external        nf_del_att

!
! attribute put/get routines:
!

      integer         nf_put_att_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             len,
!                          character(*)        text)
      external        nf_put_att_text

      integer         nf_get_att_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          character(*)        text)
      external        nf_get_att_text

      integer         nf_put_att_int1
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          nf_int1_t           i1vals(1))
      external        nf_put_att_int1

      integer         nf_get_att_int1
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          nf_int1_t           i1vals(1))
      external        nf_get_att_int1

      integer         nf_put_att_int2
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          nf_int2_t           i2vals(1))
      external        nf_put_att_int2

      integer         nf_get_att_int2
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          nf_int2_t           i2vals(1))
      external        nf_get_att_int2

      integer         nf_put_att_int
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          integer             ivals(1))
      external        nf_put_att_int

      integer         nf_get_att_int
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             ivals(1))
      external        nf_get_att_int

      integer         nf_put_att_real
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          real                rvals(1))
      external        nf_put_att_real

      integer         nf_get_att_real
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          real                rvals(1))
      external        nf_get_att_real

      integer         nf_put_att_double
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             xtype,
!                          integer             len,
!                          double              dvals(1))
      external        nf_put_att_double

      integer         nf_get_att_double
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          double              dvals(1))
      external        nf_get_att_double

!
! general variable routines:
!

      integer         nf_def_var
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             datatype,
!                          integer             ndims,
!                          integer             dimids(1),
!                          integer             varid)
      external        nf_def_var

      integer         nf_inq_var
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name,
!                          integer             datatype,
!                          integer             ndims,
!                          integer             dimids(1),
!                          integer             natts)
      external        nf_inq_var

      integer         nf_inq_varid
!                         (integer             ncid,
!                          character(*)        name,
!                          integer             varid)
      external        nf_inq_varid

      integer         nf_inq_varname
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name)
      external        nf_inq_varname

      integer         nf_inq_vartype
!                         (integer             ncid,
!                          integer             varid,
!                          integer             xtype)
      external        nf_inq_vartype

      integer         nf_inq_varndims
!                         (integer             ncid,
!                          integer             varid,
!                          integer             ndims)
      external        nf_inq_varndims

      integer         nf_inq_vardimid
!                         (integer             ncid,
!                          integer             varid,
!                          integer             dimids(1))
      external        nf_inq_vardimid

      integer         nf_inq_varnatts
!                         (integer             ncid,
!                          integer             varid,
!                          integer             natts)
      external        nf_inq_varnatts

      integer         nf_rename_var
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        name)
      external        nf_rename_var

      integer         nf_copy_var
!                         (integer             ncid_in,
!                          integer             varid,
!                          integer             ncid_out)
      external        nf_copy_var

!
! entire variable put/get routines:
!

      integer         nf_put_var_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        text)
      external        nf_put_var_text

      integer         nf_get_var_text
!                         (integer             ncid,
!                          integer             varid,
!                          character(*)        text)
      external        nf_get_var_text

      integer         nf_put_var_int1
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int1_t           i1vals(1))
      external        nf_put_var_int1

      integer         nf_get_var_int1
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int1_t           i1vals(1))
      external        nf_get_var_int1

      integer         nf_put_var_int2
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int2_t           i2vals(1))
      external        nf_put_var_int2

      integer         nf_get_var_int2
!                         (integer             ncid,
!                          integer             varid,
!                          nf_int2_t           i2vals(1))
      external        nf_get_var_int2

      integer         nf_put_var_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             ivals(1))
      external        nf_put_var_int

      integer         nf_get_var_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             ivals(1))
      external        nf_get_var_int

      integer         nf_put_var_real
!                         (integer             ncid,
!                          integer             varid,
!                          real                rvals(1))
      external        nf_put_var_real

      integer         nf_get_var_real
!                         (integer             ncid,
!                          integer             varid,
!                          real                rvals(1))
      external        nf_get_var_real

      integer         nf_put_var_double
!                         (integer             ncid,
!                          integer             varid,
!                          doubleprecision     dvals(1))
      external        nf_put_var_double

      integer         nf_get_var_double
!                         (integer             ncid,
!                          integer             varid,
!                          doubleprecision     dvals(1))
      external        nf_get_var_double

!
! single variable put/get routines:
!

      integer         nf_put_var1_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          character*1         text)
      external        nf_put_var1_text

      integer         nf_get_var1_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          character*1         text)
      external        nf_get_var1_text

      integer         nf_put_var1_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int1_t           i1val)
      external        nf_put_var1_int1

      integer         nf_get_var1_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int1_t           i1val)
      external        nf_get_var1_int1

      integer         nf_put_var1_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int2_t           i2val)
      external        nf_put_var1_int2

      integer         nf_get_var1_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          nf_int2_t           i2val)
      external        nf_get_var1_int2

      integer         nf_put_var1_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          integer             ival)
      external        nf_put_var1_int

      integer         nf_get_var1_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          integer             ival)
      external        nf_get_var1_int

      integer         nf_put_var1_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          real                rval)
      external        nf_put_var1_real

      integer         nf_get_var1_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          real                rval)
      external        nf_get_var1_real

      integer         nf_put_var1_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          doubleprecision     dval)
      external        nf_put_var1_double

      integer         nf_get_var1_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             index(1),
!                          doubleprecision     dval)
      external        nf_get_var1_double

!
! variable array put/get routines:
!

      integer         nf_put_vara_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          character(*)        text)
      external        nf_put_vara_text

      integer         nf_get_vara_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          character(*)        text)
      external        nf_get_vara_text

      integer         nf_put_vara_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int1_t           i1vals(1))
      external        nf_put_vara_int1

      integer         nf_get_vara_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int1_t           i1vals(1))
      external        nf_get_vara_int1

      integer         nf_put_vara_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int2_t           i2vals(1))
      external        nf_put_vara_int2

      integer         nf_get_vara_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          nf_int2_t           i2vals(1))
      external        nf_get_vara_int2

      integer         nf_put_vara_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             ivals(1))
      external        nf_put_vara_int

      integer         nf_get_vara_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             ivals(1))
      external        nf_get_vara_int

      integer         nf_put_vara_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          real                rvals(1))
      external        nf_put_vara_real

      integer         nf_get_vara_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          real                rvals(1))
      external        nf_get_vara_real

      integer         nf_put_vara_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          doubleprecision     dvals(1))
      external        nf_put_vara_double

      integer         nf_get_vara_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          doubleprecision     dvals(1))
      external        nf_get_vara_double

!
! strided variable put/get routines:
!

      integer         nf_put_vars_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          character(*)        text)
      external        nf_put_vars_text

      integer         nf_get_vars_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          character(*)        text)
      external        nf_get_vars_text

      integer         nf_put_vars_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int1_t           i1vals(1))
      external        nf_put_vars_int1

      integer         nf_get_vars_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int1_t           i1vals(1))
      external        nf_get_vars_int1

      integer         nf_put_vars_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int2_t           i2vals(1))
      external        nf_put_vars_int2

      integer         nf_get_vars_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          nf_int2_t           i2vals(1))
      external        nf_get_vars_int2

      integer         nf_put_vars_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             ivals(1))
      external        nf_put_vars_int

      integer         nf_get_vars_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             ivals(1))
      external        nf_get_vars_int

      integer         nf_put_vars_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          real                rvals(1))
      external        nf_put_vars_real

      integer         nf_get_vars_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          real                rvals(1))
      external        nf_get_vars_real

      integer         nf_put_vars_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          doubleprecision     dvals(1))
      external        nf_put_vars_double

      integer         nf_get_vars_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          doubleprecision     dvals(1))
      external        nf_get_vars_double

!
! mapped variable put/get routines:
!

      integer         nf_put_varm_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          character(*)        text)
      external        nf_put_varm_text

      integer         nf_get_varm_text
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          character(*)        text)
      external        nf_get_varm_text

      integer         nf_put_varm_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int1_t           i1vals(1))
      external        nf_put_varm_int1

      integer         nf_get_varm_int1
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int1_t           i1vals(1))
      external        nf_get_varm_int1

      integer         nf_put_varm_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int2_t           i2vals(1))
      external        nf_put_varm_int2

      integer         nf_get_varm_int2
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          nf_int2_t           i2vals(1))
      external        nf_get_varm_int2

      integer         nf_put_varm_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          integer             ivals(1))
      external        nf_put_varm_int

      integer         nf_get_varm_int
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          integer             ivals(1))
      external        nf_get_varm_int

      integer         nf_put_varm_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          real                rvals(1))
      external        nf_put_varm_real

      integer         nf_get_varm_real
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          real                rvals(1))
      external        nf_get_varm_real

      integer         nf_put_varm_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          doubleprecision     dvals(1))
      external        nf_put_varm_double

      integer         nf_get_varm_double
!                         (integer             ncid,
!                          integer             varid,
!                          integer             start(1),
!                          integer             count(1),
!                          integer             stride(1),
!                          integer             imap(1),
!                          doubleprecision     dvals(1))
      external        nf_get_varm_double


!     NetCDF-4.
!     This is part of netCDF-4. Copyright 2006, UCAR, See COPYRIGHT
!     file for distribution information.

!     Netcdf version 4 fortran interface.

!     $Id: netcdf4.inc,v 1.28 2010/05/25 13:53:02 ed Exp $

!     New netCDF-4 types.
      integer nf_ubyte
      integer nf_ushort
      integer nf_uint
      integer nf_int64
      integer nf_uint64
      integer nf_string
      integer nf_vlen
      integer nf_opaque
      integer nf_enum
      integer nf_compound

      parameter (nf_ubyte = 7)
      parameter (nf_ushort = 8)
      parameter (nf_uint = 9)
      parameter (nf_int64 = 10)
      parameter (nf_uint64 = 11)
      parameter (nf_string = 12)
      parameter (nf_vlen = 13)
      parameter (nf_opaque = 14)
      parameter (nf_enum = 15)
      parameter (nf_compound = 16)

!     New netCDF-4 fill values.
      integer           nf_fill_ubyte
      integer           nf_fill_ushort
!      real              nf_fill_uint
!      real              nf_fill_int64
!      real              nf_fill_uint64
      parameter (nf_fill_ubyte = 255)
      parameter (nf_fill_ushort = 65535)

!     New constants.
      integer nf_format_netcdf4
      parameter (nf_format_netcdf4 = 3)

      integer nf_format_netcdf4_classic
      parameter (nf_format_netcdf4_classic = 4)

      integer nf_netcdf4
      parameter (nf_netcdf4 = 4096)

      integer nf_classic_model
      parameter (nf_classic_model = 256)

      integer nf_chunk_seq
      parameter (nf_chunk_seq = 0)
      integer nf_chunk_sub
      parameter (nf_chunk_sub = 1)
      integer nf_chunk_sizes
      parameter (nf_chunk_sizes = 2)

      integer nf_endian_native
      parameter (nf_endian_native = 0)
      integer nf_endian_little
      parameter (nf_endian_little = 1)
      integer nf_endian_big
      parameter (nf_endian_big = 2)

!     For NF_DEF_VAR_CHUNKING
      integer nf_chunked
      parameter (nf_chunked = 0)
      integer nf_contiguous
      parameter (nf_contiguous = 1)

!     For NF_DEF_VAR_FLETCHER32
      integer nf_nochecksum
      parameter (nf_nochecksum = 0)
      integer nf_fletcher32
      parameter (nf_fletcher32 = 1)

!     For NF_DEF_VAR_DEFLATE
      integer nf_noshuffle
      parameter (nf_noshuffle = 0)
      integer nf_shuffle
      parameter (nf_shuffle = 1)

!     For NF_DEF_VAR_SZIP
      integer nf_szip_ec_option_mask
      parameter (nf_szip_ec_option_mask = 4)
      integer nf_szip_nn_option_mask
      parameter (nf_szip_nn_option_mask = 32)

!     For parallel I/O.
      integer nf_mpiio      
      parameter (nf_mpiio = 8192)
      integer nf_mpiposix
      parameter (nf_mpiposix = 16384)
      integer nf_pnetcdf
      parameter (nf_pnetcdf = 32768)

!     For NF_VAR_PAR_ACCESS.
      integer nf_independent
      parameter (nf_independent = 0)
      integer nf_collective
      parameter (nf_collective = 1)

!     New error codes.
      integer nf_ehdferr        ! Error at HDF5 layer. 
      parameter (nf_ehdferr = -101)
      integer nf_ecantread      ! Can't read. 
      parameter (nf_ecantread = -102)
      integer nf_ecantwrite     ! Can't write. 
      parameter (nf_ecantwrite = -103)
      integer nf_ecantcreate    ! Can't create. 
      parameter (nf_ecantcreate = -104)
      integer nf_efilemeta      ! Problem with file metadata. 
      parameter (nf_efilemeta = -105)
      integer nf_edimmeta       ! Problem with dimension metadata. 
      parameter (nf_edimmeta = -106)
      integer nf_eattmeta       ! Problem with attribute metadata. 
      parameter (nf_eattmeta = -107)
      integer nf_evarmeta       ! Problem with variable metadata. 
      parameter (nf_evarmeta = -108)
      integer nf_enocompound    ! Not a compound type. 
      parameter (nf_enocompound = -109)
      integer nf_eattexists     ! Attribute already exists. 
      parameter (nf_eattexists = -110)
      integer nf_enotnc4        ! Attempting netcdf-4 operation on netcdf-3 file.   
      parameter (nf_enotnc4 = -111)
      integer nf_estrictnc3     ! Attempting netcdf-4 operation on strict nc3 netcdf-4 file.   
      parameter (nf_estrictnc3 = -112)
      integer nf_enotnc3        ! Attempting netcdf-3 operation on netcdf-4 file.   
      parameter (nf_enotnc3 = -113)
      integer nf_enopar         ! Parallel operation on file opened for non-parallel access.   
      parameter (nf_enopar = -114)
      integer nf_eparinit       ! Error initializing for parallel access.   
      parameter (nf_eparinit = -115)
      integer nf_ebadgrpid      ! Bad group ID.   
      parameter (nf_ebadgrpid = -116)
      integer nf_ebadtypid      ! Bad type ID.   
      parameter (nf_ebadtypid = -117)
      integer nf_etypdefined    ! Type has already been defined and may not be edited. 
      parameter (nf_etypdefined = -118)
      integer nf_ebadfield      ! Bad field ID.   
      parameter (nf_ebadfield = -119)
      integer nf_ebadclass      ! Bad class.   
      parameter (nf_ebadclass = -120)
      integer nf_emaptype       ! Mapped access for atomic types only.   
      parameter (nf_emaptype = -121)
      integer nf_elatefill      ! Attempt to define fill value when data already exists. 
      parameter (nf_elatefill = -122)
      integer nf_elatedef       ! Attempt to define var properties, like deflate, after enddef. 
      parameter (nf_elatedef = -123)
      integer nf_edimscale      ! Probem with HDF5 dimscales. 
      parameter (nf_edimscale = -124)
      integer nf_enogrp       ! No group found.
      parameter (nf_enogrp = -125)


!     New functions.

!     Parallel I/O.
      integer nf_create_par
      external nf_create_par

      integer nf_open_par
      external nf_open_par

      integer nf_var_par_access
      external nf_var_par_access

!     Functions to handle groups.
      integer nf_inq_ncid
      external nf_inq_ncid

      integer nf_inq_grps
      external nf_inq_grps

      integer nf_inq_grpname
      external nf_inq_grpname

      integer nf_inq_grpname_full
      external nf_inq_grpname_full

      integer nf_inq_grpname_len
      external nf_inq_grpname_len

      integer nf_inq_grp_parent
      external nf_inq_grp_parent

      integer nf_inq_grp_ncid
      external nf_inq_grp_ncid

      integer nf_inq_grp_full_ncid
      external nf_inq_grp_full_ncid

      integer nf_inq_varids
      external nf_inq_varids

      integer nf_inq_dimids
      external nf_inq_dimids

      integer nf_def_grp
      external nf_def_grp

!     New rename grp function

      integer nf_rename_grp
      external nf_rename_grp

!     New options for netCDF variables.
      integer nf_def_var_deflate
      external nf_def_var_deflate

      integer nf_inq_var_deflate
      external nf_inq_var_deflate

      integer nf_def_var_fletcher32
      external nf_def_var_fletcher32

      integer nf_inq_var_fletcher32
      external nf_inq_var_fletcher32

      integer nf_def_var_chunking
      external nf_def_var_chunking

      integer nf_inq_var_chunking
      external nf_inq_var_chunking

      integer nf_def_var_fill
      external nf_def_var_fill

      integer nf_inq_var_fill
      external nf_inq_var_fill

      integer nf_def_var_endian
      external nf_def_var_endian

      integer nf_inq_var_endian
      external nf_inq_var_endian

!     User defined types.
      integer nf_inq_typeids
      external nf_inq_typeids

      integer nf_inq_typeid
      external nf_inq_typeid

      integer nf_inq_type
      external nf_inq_type

      integer nf_inq_user_type
      external nf_inq_user_type

!     User defined types - compound types.
      integer nf_def_compound
      external nf_def_compound

      integer nf_insert_compound
      external nf_insert_compound

      integer nf_insert_array_compound
      external nf_insert_array_compound

      integer nf_inq_compound
      external nf_inq_compound

      integer nf_inq_compound_name
      external nf_inq_compound_name

      integer nf_inq_compound_size
      external nf_inq_compound_size

      integer nf_inq_compound_nfields
      external nf_inq_compound_nfields

      integer nf_inq_compound_field
      external nf_inq_compound_field

      integer nf_inq_compound_fieldname
      external nf_inq_compound_fieldname

      integer nf_inq_compound_fieldindex
      external nf_inq_compound_fieldindex

      integer nf_inq_compound_fieldoffset
      external nf_inq_compound_fieldoffset

      integer nf_inq_compound_fieldtype
      external nf_inq_compound_fieldtype

      integer nf_inq_compound_fieldndims
      external nf_inq_compound_fieldndims

      integer nf_inq_compound_fielddim_sizes
      external nf_inq_compound_fielddim_sizes

!     User defined types - variable length arrays.
      integer nf_def_vlen
      external nf_def_vlen

      integer nf_inq_vlen
      external nf_inq_vlen

      integer nf_free_vlen
      external nf_free_vlen

!     User defined types - enums.
      integer nf_def_enum
      external nf_def_enum

      integer nf_insert_enum
      external nf_insert_enum

      integer nf_inq_enum
      external nf_inq_enum

      integer nf_inq_enum_member
      external nf_inq_enum_member

      integer nf_inq_enum_ident
      external nf_inq_enum_ident

!     User defined types - opaque.
      integer nf_def_opaque
      external nf_def_opaque

      integer nf_inq_opaque
      external nf_inq_opaque

!     Write and read attributes of any type, including user defined
!     types.
      integer nf_put_att
      external nf_put_att
      integer nf_get_att
      external nf_get_att

!     Write and read variables of any type, including user defined
!     types.
      integer nf_put_var
      external nf_put_var
      integer nf_put_var1
      external nf_put_var1
      integer nf_put_vara
      external nf_put_vara
      integer nf_put_vars
      external nf_put_vars
      integer nf_get_var
      external nf_get_var
      integer nf_get_var1
      external nf_get_var1
      integer nf_get_vara
      external nf_get_vara
      integer nf_get_vars
      external nf_get_vars

!     64-bit int functions.
      integer nf_put_var1_int64
      external nf_put_var1_int64
      integer nf_put_vara_int64
      external nf_put_vara_int64
      integer nf_put_vars_int64
      external nf_put_vars_int64
      integer nf_put_varm_int64
      external nf_put_varm_int64
      integer nf_put_var_int64
      external nf_put_var_int64
      integer nf_get_var1_int64
      external nf_get_var1_int64
      integer nf_get_vara_int64
      external nf_get_vara_int64
      integer nf_get_vars_int64
      external nf_get_vars_int64
      integer nf_get_varm_int64
      external nf_get_varm_int64
      integer nf_get_var_int64
      external nf_get_var_int64

!     For helping F77 users with VLENs.
      integer nf_get_vlen_element
      external nf_get_vlen_element
      integer nf_put_vlen_element
      external nf_put_vlen_element

!     For dealing with file level chunk cache.
      integer nf_set_chunk_cache
      external nf_set_chunk_cache
      integer nf_get_chunk_cache
      external nf_get_chunk_cache

!     For dealing with per variable chunk cache.
      integer nf_set_var_chunk_cache
      external nf_set_var_chunk_cache
      integer nf_get_var_chunk_cache
      external nf_get_var_chunk_cache

!     NetCDF-2.
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
! begin netcdf 2.4 backward compatibility:
!

!      
! functions in the fortran interface
!
      integer nccre
      integer ncopn
      integer ncddef
      integer ncdid
      integer ncvdef
      integer ncvid
      integer nctlen
      integer ncsfil

      external nccre
      external ncopn
      external ncddef
      external ncdid
      external ncvdef
      external ncvid
      external nctlen
      external ncsfil


      integer ncrdwr
      integer nccreat
      integer ncexcl
      integer ncindef
      integer ncnsync
      integer nchsync
      integer ncndirty
      integer nchdirty
      integer nclink
      integer ncnowrit
      integer ncwrite
      integer ncclob
      integer ncnoclob
      integer ncglobal
      integer ncfill
      integer ncnofill
      integer maxncop
      integer maxncdim
      integer maxncatt
      integer maxncvar
      integer maxncnam
      integer maxvdims
      integer ncnoerr
      integer ncebadid
      integer ncenfile
      integer nceexist
      integer nceinval
      integer nceperm
      integer ncenotin
      integer nceindef
      integer ncecoord
      integer ncemaxds
      integer ncename
      integer ncenoatt
      integer ncemaxat
      integer ncebadty
      integer ncebadd
      integer ncests
      integer nceunlim
      integer ncemaxvs
      integer ncenotvr
      integer nceglob
      integer ncenotnc
      integer ncfoobar
      integer ncsyserr
      integer ncfatal
      integer ncverbos
      integer ncentool


!
! netcdf data types:
!
      integer ncbyte
      integer ncchar
      integer ncshort
      integer nclong
      integer ncfloat
      integer ncdouble

      parameter(ncbyte = 1)
      parameter(ncchar = 2)
      parameter(ncshort = 3)
      parameter(nclong = 4)
      parameter(ncfloat = 5)
      parameter(ncdouble = 6)

!     
!     masks for the struct nc flag field; passed in as 'mode' arg to
!     nccreate and ncopen.
!     

!     read/write, 0 => readonly 
      parameter(ncrdwr = 1)
!     in create phase, cleared by ncendef 
      parameter(nccreat = 2)
!     on create destroy existing file 
      parameter(ncexcl = 4)
!     in define mode, cleared by ncendef 
      parameter(ncindef = 8)
!     synchronise numrecs on change (x'10')
      parameter(ncnsync = 16)
!     synchronise whole header on change (x'20')
      parameter(nchsync = 32)
!     numrecs has changed (x'40')
      parameter(ncndirty = 64)  
!     header info has changed (x'80')
      parameter(nchdirty = 128)
!     prefill vars on endef and increase of record, the default behavior
      parameter(ncfill = 0)
!     do not fill vars on endef and increase of record (x'100')
      parameter(ncnofill = 256)
!     isa link (x'8000')
      parameter(nclink = 32768)

!     
!     'mode' arguments for nccreate and ncopen
!     
      parameter(ncnowrit = 0)
      parameter(ncwrite = ncrdwr)
      parameter(ncclob = nf_clobber)
      parameter(ncnoclob = nf_noclobber)

!     
!     'size' argument to ncdimdef for an unlimited dimension
!     
      integer ncunlim
      parameter(ncunlim = 0)

!     
!     attribute id to put/get a global attribute
!     
      parameter(ncglobal  = 0)

!     
!     advisory maximums:
!     
      parameter(maxncop = 64)
      parameter(maxncdim = 1024)
      parameter(maxncatt = 8192)
      parameter(maxncvar = 8192)
!     not enforced 
      parameter(maxncnam = 256)
      parameter(maxvdims = maxncdim)

!     
!     global netcdf error status variable
!     initialized in error.c
!     

!     no error 
      parameter(ncnoerr = nf_noerr)
!     not a netcdf id 
      parameter(ncebadid = nf_ebadid)
!     too many netcdfs open 
      parameter(ncenfile = -31)   ! nc_syserr
!     netcdf file exists && ncnoclob
      parameter(nceexist = nf_eexist)
!     invalid argument 
      parameter(nceinval = nf_einval)
!     write to read only 
      parameter(nceperm = nf_eperm)
!     operation not allowed in data mode 
      parameter(ncenotin = nf_enotindefine )   
!     operation not allowed in define mode 
      parameter(nceindef = nf_eindefine)   
!     coordinates out of domain 
      parameter(ncecoord = nf_einvalcoords)
!     maxncdims exceeded 
      parameter(ncemaxds = nf_emaxdims)
!     string match to name in use 
      parameter(ncename = nf_enameinuse)   
!     attribute not found 
      parameter(ncenoatt = nf_enotatt)
!     maxncattrs exceeded 
      parameter(ncemaxat = nf_emaxatts)
!     not a netcdf data type 
      parameter(ncebadty = nf_ebadtype)
!     invalid dimension id 
      parameter(ncebadd = nf_ebaddim)
!     ncunlimited in the wrong index 
      parameter(nceunlim = nf_eunlimpos)
!     maxncvars exceeded 
      parameter(ncemaxvs = nf_emaxvars)
!     variable not found 
      parameter(ncenotvr = nf_enotvar)
!     action prohibited on ncglobal varid 
      parameter(nceglob = nf_eglobal)
!     not a netcdf file 
      parameter(ncenotnc = nf_enotnc)
      parameter(ncests = nf_ests)
      parameter (ncentool = nf_emaxname) 
      parameter(ncfoobar = 32)
      parameter(ncsyserr = -31)

!     
!     global options variable. used to determine behavior of error handler.
!     initialized in lerror.c
!     
      parameter(ncfatal = 1)
      parameter(ncverbos = 2)

!
!     default fill values.  these must be the same as in the c interface.
!
      integer filbyte
      integer filchar
      integer filshort
      integer fillong
      real filfloat
      doubleprecision fildoub

      parameter (filbyte = -127)
      parameter (filchar = 0)
      parameter (filshort = -32767)
      parameter (fillong = -2147483647)
      parameter (filfloat = 9.9692099683868690e+36)
      parameter (fildoub = 9.9692099683868690e+36)

    character(len=*),                      intent(in) :: outdir
    character(len=*),                      intent(in) :: version
    integer,                               intent(in) :: igrid
    character(len=*),                      intent(in) :: llanduse
    character(len=*),                      intent(in) :: olddate
    character(len=*),                      intent(in) :: startdate
    integer,                               intent(in) :: ixfull
    integer,                               intent(in) :: jxfull
    integer,                               intent(in) :: ixpar
    integer,                               intent(in) :: jxpar
    integer,                               intent(in) :: xstartpar
    integer,                               intent(in) :: ystartpar
    integer,                               intent(in) :: nsoil
    integer,                               intent(in) :: nsnow
    integer,                               intent(in) :: num_urban_layers
    real,                                  intent(in) :: dx, dy
    real,                                  intent(in) :: truelat1, truelat2
    integer,                               intent(in) :: mapproj
    real,                                  intent(in) :: lat1, lon1, cen_lon
    integer,                               intent(in) :: iswater
    integer, dimension(ixpar,jxpar),       intent(in) :: vegtyp

    character(len=1) :: hgrid
    integer :: ncid
    character(len=256) :: output_flnm
    integer :: ierr
    integer :: varid
    integer :: dimid_times, dimid_datelen, dimid_ix, dimid_jx, dimid_dum, dimid_layers, dimid_snow_layers, dimid_sosn_layers, dimid_urban
    character(len=19) :: date19
    integer :: rank


    rank = 0



    write(output_flnm, '(A,"/RESTART.",A10,"_DOMAIN",I1)') trim(outdir), olddate(1:4)//olddate(6:7)//olddate(9:10)//olddate(12:13), igrid
    if (rank==0) print*, 'output_flnm = "'//trim(output_flnm)//'"'

    restart_filename_remember = output_flnm
    iswater_remember   = iswater
    xstartpar_remember = xstartpar
    allocate(vegtyp_remember(ixpar,jxpar))
    vegtyp_remember = vegtyp

    ierr = nf90_create(trim(output_flnm), NF90_CLOBBER, ncid)

    if (ierr /= 0) stop "Problem nf_create"

    ierr = nf90_def_dim(ncid, "Time", NF90_UNLIMITED, dimid_times)
    ierr = nf90_def_dim(ncid, "DateStrLen", 19, dimid_datelen)
    ierr = nf90_def_dim(ncid, "west_east", ixfull, dimid_ix)
    ierr = nf90_def_dim(ncid, "south_north", jxfull, dimid_jx)
    ierr = nf90_def_dim(ncid, "west_east_stag", ixfull+1, dimid_dum)
    ierr = nf90_def_dim(ncid, "south_north_stag", jxfull+1, dimid_dum)
    ierr = nf90_def_dim(ncid, "soil_layers_stag", nsoil, dimid_layers)
    ierr = nf90_def_dim(ncid, "snow_layers", nsnow, dimid_snow_layers)
    ierr = nf90_def_dim(ncid, "sosn_layers", nsnow+nsoil, dimid_sosn_layers)
    ierr = nf90_def_dim(ncid, "urban_layers", num_urban_layers, dimid_urban)

    ierr = nf90_put_att(ncid, NF90_GLOBAL, "TITLE", "RESTART FILE FROM HRLDAS "//version)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "missing_value", -1.E33)

    date19(1:19) = "0000-00-00_00:00:00"
    date19(1:len_trim(startdate)) = startdate

    ierr = nf90_put_att(ncid, NF90_GLOBAL, "START_DATE", date19)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "MAP_PROJ", mapproj)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "LAT1", lat1)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "LON1", lon1)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "DX", dx)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "DY", dy)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "TRUELAT1", truelat1)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "TRUELAT2", truelat2)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "STAND_LON", cen_lon)
    ierr = nf90_put_att(ncid, NF90_GLOBAL, "MMINLU", llanduse)

!
! Done with dimensions and global attributes.
! Now define and describe all our NetCDF restart variables.
!

    ierr = nf90_def_var(ncid,  "Times",  NF90_CHAR, (/dimid_datelen,dimid_times/), varid)
    ierr = nf90_enddef(ncid)

!
! Done defining and describing all our NetCDF restart variables.
! Now actually put the data for each variable into the NetCDF file.
!

    date19(1:19) = "0000-00-00_00:00:00"
    date19(1:len_trim(olddate)) = olddate

    ierr = nf90_inq_varid(ncid, "Times", varid)
    call error_handler(ierr, "WRITE_RESTART:  Problem inquiring varid for 'Times'")

!    write(6,*) "yywww olddate  = ", olddate
!    write(6,*) "yywww output_count_remember  = ", output_count_remember

    ierr = nf90_put_var(ncid, varid, olddate, (/1,1/), (/19,1/))
    call error_handler(ierr, "WRITE_RESTART:  problem putting 'Times' to restart file")

    ierr = nf90_close(ncid)
    call error_handler(ierr, "WRITE_RESTART:  nf90_close")

  end subroutine prepare_restart_file_seq

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine add_to_restart_2d_float(array, name, units, description)
    implicit none
    real,            dimension(:,:),                              intent(in) :: array
    character(len=*),                                             intent(in) :: name
    character(len=*), optional,                                   intent(in) :: units
    character(len=*), optional,                                   intent(in) :: description

    character(len=256) :: output_flnm
    integer :: ncid
    integer :: ierr
    integer :: dimid_ix
    integer :: dimid_jx
    integer :: dimid_times
    integer :: ixout
    integer :: xstartout
    integer :: iswater
    character(len=256) :: local_units
    character(len=256) :: local_description

    integer :: ixpar
    integer :: jxpar

    output_flnm = restart_filename_remember
    iswater     = iswater_remember

    ixpar = size(array,1)
    jxpar = size(array,2)

    if (present(units)) then
       local_units = units
    else
       local_units = "-"
    endif

    if (present(description)) then
       local_description = description
    else
       local_description = "-"
    endif
    
    ierr = nf90_open(trim(output_flnm), NF90_WRITE, ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_open")

    ierr = nf90_inq_dimid(ncid, "west_east", dimid_ix)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'west_east'")

    ierr = nf90_inq_dimid(ncid, "south_north", dimid_jx)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'south_north'")

    ierr = nf90_inq_dimid(ncid, "Time", dimid_times)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'Time'")

    ierr = nf90_redef(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_redef")

    call make_var_att_2d(ncid, dimid_ix, dimid_jx, dimid_times, NF90_FLOAT, name, trim(local_description), trim(local_units))

    ierr = nf90_enddef(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_enddef")

    call put_var_2d(ncid, 1, vegtyp_remember, iswater, ixpar, jxpar, xstartpar_remember, name, array, .true.)

    ierr = nf90_close(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_close")

  end subroutine add_to_restart_2d_float

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine add_to_restart_2d_integer(array, name, units, description)
    implicit none
    integer,         dimension(:,:),                              intent(in) :: array
    character(len=*),                                             intent(in) :: name
    character(len=*), optional,                                   intent(in) :: units
    character(len=*), optional,                                   intent(in) :: description

    character(len=256) :: output_flnm
    integer :: ncid
    integer :: ierr
    integer :: dimid_ix
    integer :: dimid_jx
    integer :: dimid_times
    integer :: ixout
    integer :: xstartout
    integer :: iswater
    character(len=256) :: local_units
    character(len=256) :: local_description

    integer :: ixpar
    integer :: jxpar

    output_flnm = restart_filename_remember
    iswater     = iswater_remember

    ixpar = size(array,1)
    jxpar = size(array,2)

    if (present(units)) then
       local_units = units
    else
       local_units = "-"
    endif

    if (present(description)) then
       local_description = description
    else
       local_description = "-"
    endif
    
    ierr = nf90_open(trim(output_flnm), NF90_WRITE, ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_open")

    ierr = nf90_inq_dimid(ncid, "west_east", dimid_ix)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'west_east'")

    ierr = nf90_inq_dimid(ncid, "south_north", dimid_jx)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'south_north'")

    ierr = nf90_inq_dimid(ncid, "Time", dimid_times)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'Time'")

    ierr = nf90_redef(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_redef")

    call make_var_att_2d(ncid, dimid_ix, dimid_jx, dimid_times, NF90_INT, name, trim(local_description), trim(local_units))

    ierr = nf90_enddef(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_enddef")

    call put_var_int(ncid, 1, vegtyp_remember, iswater, ixpar, jxpar, xstartpar_remember, name, array)

    ierr = nf90_close(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_close")

  end subroutine add_to_restart_2d_integer

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine add_to_restart_3d(array, name, units, description, layers)
    implicit none
    real,            dimension(:,:,:),                            intent(in) :: array
    character(len=*),                                             intent(in) :: name
    character(len=*), optional,                                   intent(in) :: units
    character(len=*), optional,                                   intent(in) :: description
    character(len=4), optional,                                   intent(in) :: layers

    character(len=256) :: output_flnm
    integer :: ncid
    integer :: ierr
    integer :: dimid_ix
    integer :: dimid_jx
    integer :: dimid_kx
    integer :: dimid_times
    integer :: ixout
    integer :: xstartout
    integer :: iswater
    character(len=256) :: local_units
    character(len=256) :: local_description

    integer :: ixpar
    integer :: jxpar
    integer :: kxpar
    character(len=4) :: output_layers

    output_flnm = restart_filename_remember
    iswater     = iswater_remember

    if (present(layers)) then
       output_layers = layers
    else
       output_layers = "SOIL"
    endif

    ixpar = size(array,1)
    kxpar = size(array,2)
    jxpar = size(array,3)

    if (present(units)) then
       local_units = units
    else
       local_units = "-"
    endif

    if (present(description)) then
       local_description = description
    else
       local_description = "-"
    endif
    
    ierr = nf90_open(trim(output_flnm), NF90_WRITE, ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_open")

    ierr = nf90_inq_dimid(ncid, "west_east", dimid_ix)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'west_east'")

    ierr = nf90_inq_dimid(ncid, "south_north", dimid_jx)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'south_north'")

    if (output_layers == "SOIL") then
       ierr = nf90_inq_dimid(ncid, "soil_layers_stag", dimid_kx)
       call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'soil_layers_stag'")
    else if (output_layers == "SNOW") then
       ierr = nf90_inq_dimid(ncid, "snow_layers", dimid_kx)
       call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'snow_layers'")
    else if (output_layers == "SOSN") then
       ierr = nf90_inq_dimid(ncid, "sosn_layers", dimid_kx)
       call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'sosn_layers'")
    else if (output_layers == "URBN") then
       ierr = nf90_inq_dimid(ncid, "urban_layers", dimid_kx)
       call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'urban_layers'")
    else
       stop "PANIC!"
    endif

    ierr = nf90_inq_dimid(ncid, "Time", dimid_times)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_inq_dimid for 'Time'")

    ierr = nf90_redef(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_redef")

    call make_var_att_3d(ncid, dimid_ix, dimid_jx, dimid_times, NF90_FLOAT, dimid_kx, name, trim(local_description), trim(local_units))

    ierr = nf90_enddef(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_enddef")

    call put_var_3d(ncid, 1, vegtyp_remember, iswater, ixpar, jxpar, xstartpar_remember, kxpar, name, array)

    ierr = nf90_close(ncid)
    call error_handler(ierr, "ADD_TO_RESTART:  nf90_close")

  end subroutine add_to_restart_3d

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine read_restart(restart_flnm,  &
       parallel_xstart, parallel_xend, subwindow_xstart, ix, jx, nsoil,    &
       olddate)

    ! The restart file is dimensioned by our (possibly subwindowed) grid.  Our indices
    ! for the parallel I/O reflect the dimensions of the (possibly subwindowed) grid, 
    ! but not the full domain for which LDAS input files may be available.

    implicit none

    character(len=*),             intent(in)  :: restart_flnm
    integer,                      intent(in)  :: parallel_xstart
    integer,                      intent(in)  :: parallel_xend
    integer,                      intent(in)  :: subwindow_xstart
    integer,                      intent(in)  :: ix
    integer,                      intent(in)  :: jx
    integer,                      intent(in)  :: nsoil
    character(len=19),            intent(out) :: olddate

    integer :: ierr
    integer :: ncid
    integer :: varid
    character(len=256) :: titlestr
    integer :: restart_version
    integer :: idx
    integer, dimension(4) :: nstart
    integer, dimension(4) :: ncount
    integer :: rank
    integer :: read_sfcdif


    restart_filename_remember = restart_flnm

    rank = 0
    ierr = nf90_open(trim(restart_flnm), NF90_NOWRITE, ncid)

    if (ierr == NF90_ENOTNC) then
       print*, "IERR = NF90_ENOTNC"

    else
       if (ierr /= NF90_NOERR) then
          write(*,*)
          write(*,'(" ***** Restart problem ***************************************")')
          write(*,'(" ***** ")')
          write(*,'(" *****        There was a problem in accessing the file ''", A, "''")') trim(restart_flnm)
          write(*,'(" ***** ")')
       endif
       call error_handler(ierr, " trying to open restart file "//restart_flnm)

       ierr = nf90_get_att(ncid, NF90_GLOBAL, "TITLE", titlestr)
       if (ierr /= 0) then
          write(*,'("WARNING:  RESTART file does not have TITLE attribute.")')
          write(*,'("          This probably means that LDASIN files are from an older release,")')
          write(*,'("          And are very likely incompatible with the current code.")')
          write(*,'("          I assume you know what you are doing.")')
          restart_version = 0
       else
          if (rank == 0) write(*,'("RESTART TITLE attribute: ", A)') trim(titlestr)
          ! Pull out the version number, assuming that the version is identified by vYYYYMMDD, and 
          ! based on a search for the string "v20".
          idx = index(trim(titlestr), "v20")
          if (idx <= 0) then
             write(*,'("FATAL:  RESTART file has a perverse version identifier")')
             !  write(*,'("          I assume you know what you are doing.")')
             stop
          else
             read(titlestr(idx+1:), '(I8)', iostat=ierr) restart_version
             if (ierr /= 0) then
                write(*,'("FATAL:  RESTART file has a perverse version identifier")')
                !  write(*,'("          I assume you know what you are doing.")')
                stop
             endif
          endif
       endif

       ! Get the time stamp from the restart file.
       ierr = nf90_inq_varid(ncid, "Times", varid)
       call error_handler(ierr, "Problem finding variable in restart file: 'Times'")
       
       ierr = nf90_get_var(ncid, varid, olddate)
       call error_handler(ierr, "Problem finding variable in restart file: 'Times'")

       ierr = nf90_close(ncid)
       call error_handler(ierr, "Problem closing restart file")
    endif

  end subroutine read_restart

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine get_from_restart_att(itime)
    implicit none
    integer,intent(out) :: itime
    integer  :: ncid, ierr
        ierr = nf90_open(trim(restart_filename_remember), NF90_NOWRITE, ncid)
        ierr = nf90_get_att(ncid, NF90_GLOBAL, "ITIMESTEP", itime)
        call error_handler(ierr, failure="restart info:  Problems finding global attribute 'ITIMESTEP'")
         ierr = nf90_close(ncid)
  end subroutine get_from_restart_att

  subroutine get_from_restart_2d_float(parallel_xstart, parallel_xend, subwindow_xstart, ixfull, jxfull, name, array, return_error)
    implicit none
    integer,                            intent(in) :: parallel_xstart
    integer,                            intent(in) :: parallel_xend
    integer,                            intent(in) :: subwindow_xstart
    integer,                            intent(in) :: ixfull
    integer,                            intent(in) :: jxfull
    character(len=*),                   intent(in)  :: name
    real,             dimension(parallel_xstart:parallel_xend,jxfull), intent(out) :: array
    integer,          optional,         intent(out) :: return_error

    integer :: ierr
    integer :: ncid
    integer :: varid
    integer, dimension(4) :: nstart
    integer, dimension(4) :: ncount
    integer :: rank

    rank = 0

    ierr = nf90_open(trim(restart_filename_remember), NF90_NOWRITE, ncid)

    call error_handler(ierr, "GET_FROM_RESTART: Problem opening restart file '"//trim(restart_filename_remember)//"'")

    nstart = (/ parallel_xstart-subwindow_xstart+1, 1,  1, -99999 /)
    ncount = (/ parallel_xend-parallel_xstart+1,   jxfull,  1, -99999 /)

    if (present(return_error)) then
       ierr = nf90_inq_varid(ncid, name, varid)
       if (ierr == NF90_NOERR) then
          return_error = 0
          call error_handler(ierr, "Problem finding variable in restart file '"//trim(name)//"'")

          ierr = nf90_get_var(ncid, varid, array, start=nstart(1:3))
          call error_handler(ierr, "Problem finding variable in restart file: '"//trim(name)//"'")
       else
          return_error = 1
          if (rank == 0) write(*,'("Did not find optional variable ''",A,"'' in restart file ''", A, "''")') trim(name), trim(restart_filename_remember)
       endif
    else
       ierr = nf90_inq_varid(ncid, name, varid)
       call error_handler(ierr, "Problem finding required variable in restart file: '"//trim(name)//"'")

       ierr = nf90_get_var(ncid, varid, array, start=nstart(1:3))
       call error_handler(ierr, "Problem finding variable in restart file: '"//trim(name)//"'")
    endif

    ierr = nf90_close(ncid)
    call error_handler(ierr, "Problem closing restart file")
    
  end subroutine get_from_restart_2d_float

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine get_from_restart_2d_integer(parallel_xstart, parallel_xend, subwindow_xstart, ixfull, jxfull, name, array, return_error)
    implicit none
    integer,                                                           intent(in) :: parallel_xstart
    integer,                                                           intent(in) :: parallel_xend
    integer,                                                           intent(in) :: subwindow_xstart
    integer,                                                           intent(in) :: ixfull
    integer,                                                           intent(in) :: jxfull
    character(len=*),                                                  intent(in)  :: name
    integer,          dimension(parallel_xstart:parallel_xend,jxfull), intent(out) :: array
    integer,          optional,                                        intent(out) :: return_error

    integer :: ierr
    integer :: ncid
    integer :: varid
    integer, dimension(4) :: nstart
    integer, dimension(4) :: ncount

    ierr = nf90_open(trim(restart_filename_remember), NF90_NOWRITE, ncid)
    call error_handler(ierr, "GET_FROM_RESTART: Problem opening restart file '"//trim(restart_filename_remember)//"'")

    nstart = (/ parallel_xstart-subwindow_xstart+1, 1,  1, -99999 /)
    ncount = (/ parallel_xend-parallel_xstart+1,   jxfull,  1, -99999 /)

    if (present(return_error)) then
       ierr = nf90_inq_varid(ncid, name, varid)
       if (ierr == NF90_NOERR) then
          return_error = 0
          call error_handler(ierr, "Problem finding variable in restart file '"//trim(name)//"'")

          ierr = nf90_get_var(ncid, varid, array, start=nstart(1:3))
          call error_handler(ierr, "Problem finding variable in restart file: '"//trim(name)//"'")
       else
          return_error = 1
          write(*,'("Did not find optional variable ''",A,"'' in restart file ''", A, "''")') trim(name), trim(restart_filename_remember)
       endif
    else
       ierr = nf90_inq_varid(ncid, name, varid)
       call error_handler(ierr, "Problem finding required variable in restart file: '"//trim(name)//"'")

       ierr = nf90_get_var(ncid, varid, array, start=nstart(1:3))
       call error_handler(ierr, "Problem finding variable in restart file: '"//trim(name)//"'")
    endif

    ierr = nf90_close(ncid)
    call error_handler(ierr, "Problem closing restart file")
    
  end subroutine get_from_restart_2d_integer

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine get_from_restart_3d(parallel_xstart, parallel_xend, subwindow_xstart, ixfull, jxfull, name, array, return_error)
    implicit none
    integer,                            intent(in) :: parallel_xstart
    integer,                            intent(in) :: parallel_xend
    integer,                            intent(in) :: subwindow_xstart
    integer,                            intent(in) :: ixfull
    integer,                            intent(in) :: jxfull
    character(len=*),                   intent(in)  :: name
    real,             dimension(:,:,:), intent(out) :: array
    integer,          optional,         intent(out) :: return_error

    integer :: ierr
    integer :: ncid
    integer :: varid
    integer, dimension(4) :: nstart
    integer, dimension(4) :: ncount

    ierr = nf90_open(trim(restart_filename_remember), NF90_NOWRITE, ncid)
    call error_handler(ierr, "GET_FROM_RESTART: Problem opening restart file '"//trim(restart_filename_remember)//"'")

    nstart = (/parallel_xstart-subwindow_xstart+1,1, 1, 1/)
    ncount = (/parallel_xend-parallel_xstart+1, size(array,2), size(array,3), 1/)

    if (present(return_error)) then
       ierr = nf90_inq_varid(ncid, name, varid)
       if (ierr == NF90_NOERR) then
          return_error = 0
          call error_handler(ierr, "Problem finding variable in restart file '"//trim(name)//"'")

          ierr = nf90_get_var(ncid, varid, array, start=nstart(1:4))
          call error_handler(ierr, "Problem finding variable in restart file: '"//trim(name)//"'")
       else
          return_error = 1
          write(*,'("Did not find optional variable ''",A,"'' in restart file ''", A, "''")') trim(name), trim(restart_filename_remember)
       endif
    else
       ierr = nf90_inq_varid(ncid, name, varid)
       call error_handler(ierr, "Problem finding required variable in restart file: '"//trim(name)//"'")

       ierr = nf90_get_var(ncid, varid, array, start=nstart(1:4))
       call error_handler(ierr, "Problem finding variable in restart file: '"//trim(name)//"'")
    endif

    ierr = nf90_close(ncid)
    call error_handler(ierr, "Problem closing restart file")
    
  end subroutine get_from_restart_3d

!-----------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------

  subroutine error_handler(status, failure, success)
    !
    ! Check the error flag from a NetCDF function call, and print appropriate
    ! error message.
    !
    implicit none
    integer,                    intent(in) :: status
    character(len=*), optional, intent(in) :: failure
    character(len=*), optional, intent(in) :: success

    if (status .ne. NF90_NOERR) then
       write(*,'(/,A)') nf90_strerror(status)
       if (present(failure)) then
          write(*,'(/," ***** ", A,/)') failure
       endif
       stop 'Stopped'
    endif

    if (present(success)) then
       write(*,'(A)') success
    endif

  end subroutine error_handler

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

  subroutine read_additional(flnm_template, hdate, name, xstart, xend, ystart, yend, array, ierr)
    use kwm_string_utilities
    implicit none
    character(len=*),                         intent(in)  :: flnm_template
    character(len=*),                         intent(in)  :: hdate
    character(len=*),                         intent(in)  :: name
    integer,                                  intent(in)  :: xstart
    integer,                                  intent(in)  :: xend
    integer,                                  intent(in)  :: ystart
    integer,                                  intent(in)  :: yend
    real, dimension(xstart:xend,ystart:yend), intent(out) :: array
    integer,                                  intent(out) :: ierr

    character(len=256) :: flnm
    integer :: jday
    character(len=3) :: hjday
    integer :: ncid
    integer :: varid
    logical :: lexist

    call geth_idts(hdate(1:10), hdate(1:4)//"-01-01", jday)
    jday = jday + 1
    write(hjday,'(I3.3)') jday

    flnm = flnm_template

    call strrep(flnm, "<YYYY>", hdate(1:4))
    call strrep(flnm, "<MM>", hdate(6:7))
    call strrep(flnm, "<DD>", hdate(9:10))
    call strrep(flnm, "<HH>", hdate(12:13))
    call strrep(flnm, "<JDAY>", hjday)

    inquire(file=trim(flnm), exist=lexist)
    if (.not. lexist) then
       ierr = 1
       return
    endif

    write(*, '("Additional flnm = ''",A,"''")') trim(flnm)

    ierr = nf90_open(trim(flnm), NF90_NOWRITE, ncid)
    call error_handler(ierr, failure="READ_ADDITIONAL: Problem opening additional file: "//trim(flnm))

    ierr = nf90_inq_varid(ncid,  name,  varid)
    call error_handler(ierr, failure="READ_ADDITIONAL: Problem finding variable: "//name)

    ierr = nf90_get_var(ncid, varid, array, start=(/xstart,ystart/), count=(/xend-xstart+1,yend-ystart+1/))
    call error_handler(ierr, failure="READ_ADDITIONAL: Problem getting variable: "//name)

    ierr = nf90_close(ncid)
    call error_handler(ierr, failure="READ_ADDITIONAL:  Problem closing file:  "//trim(flnm))

  end subroutine read_additional

!---------------------------------------------------------------------------------------------------------
!---------------------------------------------------------------------------------------------------------

 end module module_hrldas_netcdf_io
