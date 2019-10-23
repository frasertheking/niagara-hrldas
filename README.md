# hrldas

This guide will help you get HRLDAS set up and running on niagara. It builds on the work done by Michael Barlage (https://github.com/barlage) from the official release branch of HRLDAS (https://github.com/NCAR/hrldas-release).

## Part 1
###############################
Data Aquisition

1. First, log into Scinet. We are using Niagara for this tutorial. We put all heavy components in our $SCRATCH and the actual code for NoahMP in our user home directory. 

2. First we need some data to work with, in this tutorial we will be using the GLDAS_NOAH025_3H.2.1 product from https://hydro1.gesdisc.eosdis.nasa.gov/data/GLDAS/GLDAS_NOAH025_3H.2.1/. Download this dataset for however long you are interested in a running a simulation for and place it in your $SCRATCH on scinet.

3. We need to download the WRF preprocessing system (WPS) along with HRLDAS. These can be found here (https://github.com/wrf-model/WPS) and here (https://github.com/NCAR/hrldas-release). Simply git clone these into a main working directory in your home directoy on scinet.

4. Finally, we are going to need to download the WPS Geographical Static Data (http://www2.mmm.ucar.edu/wrf/users/download/get_sources_wps_geog.html) which is a mandatory dataset form running WPS. You will likely want to download the high resolution version which is about 30 GB. Place this in your $SCRATCH as well on scinet.

## Part 2
###############################
Building WPS and HRLDAS

5. We need to install a few modules to get started. These modules contain libraries needed for WPS and HRLDAS. Run:

```
module load CCEnv
module load StdEnv

module load nixpkgs/16.09
module load intel/2018.3
module load openmpi/3.1.2
module load wrf/3.9.1.1
module load wps/3.9.1
```

Then install the modules for HrLDAS
```
module load gcc/7.3.0
module load hdf5/1.8.20
module load netcdf/4.6.1
module load jasper"
```

7. To build HRLDAS, navigate through the installation directory to hrldas-release-master/HRLDAS and run:

```
./configure
```
Select the serial gfortran option.

Open the *user_build_options* file that was created and edit it to match the following:

```
 COMPILERF90    =       gfortran
 FREESOURCE     =       -ffree-form  -ffree-line-length-none
 F90FLAGS       =       -g -fconvert=big-endian -fbounds-check -fno-range-check #-fno-underscoring
 MODFLAG        =       -I
 LDFLAGS        =       
 CPP            =       cpp
 CPPFLAGS       =       -P -traditional -D_GFORTRAN_
 LIBS           =       
 LIBJASPER      =       -ljpeg -ljasper
 INCJASPER      =       -I/scinet/niagara/software/2018a/opt/gcc-7.3.0/jasper/2.0.14/include/jasper
 NETCDFMOD      =       -I/scinet/niagara/software/2018a/opt/gcc-7.3.0/netcdf/4.6.1/include
 NETCDFLIB      =       -lnetcdf -lnetcdff
 BZIP2          =       NO
 BZIP2_LIB      =       -lbz2
 BZIP2_INCLUDE  =       -I/opt/local/include
 RM             =       rm -f
 CC             =       gcc
```

If successful, this will create two executables:

HRLDAS_forcing/create_forcing.exe
run/hrldas.exe

## Part 3
###############################
Configuration

8. You will now need to run WPS to generate a geo_em file which defines our study region/period. Edit the namelist.wps file inside your WPS installation and run:

```
./compile
```

9. Now, using the GLDAS data we downloaded earlier, we need to break the single file up into multiple files for the parameters of interest:

mkdir Rainf/ Snowf/ Wind/ Tair/ Qair/ Psurf/ SWdown/ LWdown/ SWdown24/ Precip/  U/  V/ INIT/


