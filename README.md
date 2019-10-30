# hrldas

This guide will help you get HRLDAS set up and running on niagara. It builds on the work done by Michael Barlage (https://github.com/barlage) from the official release branch of HRLDAS (https://github.com/NCAR/hrldas-release).


## Data/Software Aquisition


Before we can do anything with HRLDAS on scinet, we need to download the suite of programs and raw forcing data we want to use.

1. First, log into Scinet. We are using Niagara for this tutorial. We want to place all of our data in our $SCRATCH and the actual code for NoahMP in our user home directory. Make a NoahMP directory in each location and save those paths for later.

2. Next we need some data to work with, in this tutorial we will be using the GLDAS_NOAH025_3H.2.1 product from https://hydro1.gesdisc.eosdis.nasa.gov/data/GLDAS/GLDAS_NOAH025_3H.2.1/. You can use different datasets for the forcings as long as you have access to the VTABLED for said data. Other options include NARR or ERA5 for instance. Download your dataset of interest for however long you plan to a running a simulation for, and place it in your NoahMP directory in $SCRATCH.

3. Now we need to download the WRF preprocessing system (WPS) along with HRLDAS. These can be found here (https://github.com/wrf-model/WPS) and here (https://github.com/NCAR/hrldas-release). We need these to generate the geo_em files which describe our study domain. Simply git clone these into a main working directory in your home directoy on scinet.

4. Finally, we are going to need to download the WPS Geographical Static Data (http://www2.mmm.ucar.edu/wrf/users/download/get_sources_wps_geog.html) which is a mandatory dataset form running WPS. You will likely want to download the high resolution version which is about 30 GB. Place this in your NoahMP directory on $SCRATCH as well.


## Building WRF, WPS and HRLDAS


Before we can compile HRLDAS, we need to install a few dependencies. These libraries contain necessary components for running WPS and HRLDAS. Luckily we can just use the WPS package on scinet, however we need to actually compile HRLDAS. If you would like to run WRF and WPS on you machine (this is what I do) feel free to skip the WPS installion module steps and move straight to HRLDAS. 

5. To install the required modules, run the following commands:

### WPS
```
module load CCEnv
module load StdEnv

module load nixpkgs/16.09
module load intel/2018.3
module load openmpi/3.1.2
module load wrf/3.9.1.1
module load wps/3.9.1
```

### HRLDAS
```
module load gcc/7.3.0
module load hdf5/1.8.20
module load netcdf/4.6.1
module load jasper"
```

7. To build HRLDAS, navigate through the installation directory to hrldas-release-master/HRLDAS (stay here for steps 8 and 9 as well) and run:

```
./configure
```
Select *OPTION 5*. This is the serial gfortran option. You can of course compile use intel compilers or with MPI enabled, but for this tutorial we are going to stick to the basics of serial gfortan.

8. Now, open the *user_build_options* file that was created and edit it so that it matches the following:

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

A key thing to note is the exclusion of (-fno-underscoring) which is not supported on scinet under this configuration.

9. We HRLDAS configuration complete, we now simply need to compile everything. To do so, run:


```
./compile
```

This doesn't take too long and there may be a few warnings issued along the way, however if successful, this will create two executable files:

HRLDAS_forcing/*create_forcing.exe*
run/*hrldas.exe*

Just beautiful, aren't they?


## Preparing Ancillary Data

Great! You are making excellent progress and are over half way done. Now comes the (potentially) tricky part however, you need to organize your forcing and initialization data to feed into the HRLDAS preprocessor. I say this is potentially tricky since we need to work with GRIB files here and if your data is in netCDF format then it can be a bit of a pain properly converting it to GRIB. Otherwise it is not too bad. 

In short, we need the following data:

* a) We need a single file per forcing, per timestep ∀ timesteps
* b) We need initialization data for a set of forcing parameters
* c) We need the geoem file produced by WPS to define our study domain
* d) We need a land sea mask which matches the resolution of our forcing data
* e) We need an elevation dataset which matches  the resolution of our forcing data
* f) All of these need to be in GRB format (V1 or V2) with the proper indicatorParameters to match our dataset VTABLE.

10. The process for a) typically depends on forcing data you wish to use. ERA5 for insatnce allows you to download GRIB data for each forcing individually. While the GLDAS data we are using are single netCDF files for all forcings which is more work to break up and convert. I won't go through the exact steps I took here, but using whatever language you are most comfortable with, we need to break the data up into the following directories in your NoahMP fdirectory in $SCRATCH:

```
Rainf Snowf Wind Tair Qair Psurf SWdown LWdown SWdown24 Precip U V INIT
```

These values are based on the VTABLE we use for GLDAS:


```
<VTABLE>
-----+------+------+------+----------+-----------+-----------------------------------------+-----------------------+
GRIB1| Level| From |  To  |          |           |                                         |GRIB2|GRIB2|GRIB2|GRIB2|
Param| Type |Level1|Level2| Name     | Units     | Description                             |Discp|Catgy|Param|Level|
-----+------+------+------+----------+-----------+-----------------------------------------+-----------------------+
  11 |   1  |   0  |      | T2D      | K         | Temperature       at 2 m                |  0  |  0  |  0  | 103 |
  51 |   1  |   0  |      | Q2D      | kg/kg     | Specific Humidity at 2 m                |  0  |  1  |  0  | 103 |
  33 |   1  |   0  |      | U2D      | m/s       | U                 at 10 m               |  0  |  2  |  2  | 103 |
  34 |   1  |   0  |      | V2D      | m/s       | V                 at 10 m               |  0  |  2  |  3  | 103 |
   1 |   1  |   0  |      | PSFC     | Pa        | Surface Pressure                        |  0  |  3  |  0  |   1 |
  59 |   1  |   0  |      | RAINRATE | kg/m^2/s  | Precipitation Rate                      |  0  |  1  |  8  |   1 |
 116 |   1  |   0  |      | SWDOWN   | W/m^2     | Downward short-wave radiation flux      |  0  |  4  | 192 |   1 |
 115 |   1  |   0  |      | LWDOWN   | W/m^2     | Downward long-wave radiation flux       |  0  |  5  | 192 |   1 |
  81 |   1  |   0  |      | LANDSEA  | proprtn   | Land/Sea flag (1=land,0=sea in NAM)     |  2  |  0  |  0  |   1 |
   7 |   1  |   0  |      | TERRAIN  | m         | Terrain field of source analysis        |  2  |  0  |  7  |   1 |
 138 |   1  |   0  |      | TSK      | K         | Skin temperature                        |  0  |  0  |  0  |   1 |
  65 |   1  |   0  |      | SNOW     | kg/m^2    | Water equivalent snow depth             |  0  |  1  | 13  |   1 |
  71 |   1  |   0  |      | CANWAT   | kg/m^2    | Plant Canopy Surface Water              |  2  |  0  | 196 |   1 |
  86 | 112  |   0  |   4  | SMOIS_1  | gldas     | Soil Moist 0-10 cm below grn layer (Up) |  2  |  0  | 192 | 106 |
  86 | 112  |   0  |   3  | SMOIS_2  | gldas     | Soil Moist 10-40 cm below grn layer     |  2  |  0  | 192 | 106 |
  86 | 112  |   0  |   2  | SMOIS_3  | gldas     | Soil Moist 40-100 cm below grn layer    |  2  |  0  | 192 | 106 |
  86 | 112  |   0  |   1  | SMOIS_4  | gldas     | Soil Moist 100-200 cm below gr layer    |  2  |  0  | 192 | 106 |
  85 | 112  |   0  |   4  | STEMP_1  | K         | T 0-10 cm below ground layer (Upper)    |  2  |  0  |  2  | 106 |
  85 | 112  |   0  |   3  | STEMP_2  | K         | T 10-40 cm below ground layer (Upper)   |  2  |  0  |  2  | 106 |
  85 | 112  |   0  |   2  | STEMP_3  | K         | T 40-100 cm below ground layer (Upper)  |  2  |  0  |  2  | 106 |
  85 | 112  |   0  |   1  | STEMP_4  | K         | T 100-200 cm below ground layer (Bottom)|  2  |  0  |  2  | 106 |
-----+------+------+------+----------+-----------+-----------------------------------------+-----------------------+
</VTABLE>

```

More details on these paramaters can be found here (https://github.com/NCAR/hrldas/tree/master/hrldas).

11. For b), we next need to do a similar procedure for a single timestep (timestep 0) for a few other parametrs to create our initialization files (these go in INIT). You can skip this step if you don't want to initialize using GLDAS states in this case. The INIT variables are:

```
T2D CANWAT SMOIS(1-4) STEMP(1-4) SNOW
```

12. For c), follow the steps outlined here (https://github.com/NCAR/hrldas/tree/master/hrldas) for running WRF, WPS and generating a geo_em file. Again, I do this step on my own machine, however we have installed WPS on scinet in step 5, so you can also do this on Niagara if you'd like. 

13. For steps d) and e), you will need to find these files online for your forcing datasets. Place these in $SCRATCH as well.

14. Now pop right into the HRLDAS_forcing directory and edit the namelist.input.GLDAS file. You will need to configure the start and end data, the path to the forcing data you have organized in steps 10-13  and set up the links to a few other components like the geo_em file. Mine looks something like:

```
 STARTDATE          = "2011-01-01_00"
 ENDDATE            = "2011-01-01_06"
 DataDir            = "/scratch/c/cgf/fdmking/hrldas/data"
 OutputDir          = "/scratch/c/cgf/fdmking/hrldas/LDASIN/"
 FULL_IC_FRQ        = 1
 RAINFALL_INTERP    = 0
 RESCALE_SHORTWAVE  = .FALSE.
 UPDATE_SNOW        = .FALSE.
 FORCING_HEIGHT_2D  = .FALSE.
 TRUNCATE_SW        = .FALSE.
 EXPAND_LOOP        = 2
 INIT_LAI           = .TRUE.
 VARY_LAI           = .TRUE.
 MASK_WATER         = .TRUE.
 expand_loop        = 2

 geo_em_flnm        = "/scratch/c/cgf/fdmking/hrldas/data/misc/geo_em.d01.nc"

 Zfile_template     = "/scratch/c/cgf/fdmking/hrldas/data/misc/GLDAS_ELEVATION.grb"
 LANDSfile_template = "/scratch/c/cgf/fdmking/hrldas/data/misc/GLDAS_LANDSEA2.grb"
 Tfile_template     = "<DataDir>/Tair/GLDAS_Tair.<date>.grb"
 Ufile_template     = "<DataDir>/U/GLDAS_Wind.<date>.grb",
 Vfile_template     = "<DataDir>/V/GLDAS_Wind.<date>.grb",
 Pfile_template     = "<DataDir>/Psurf/GLDAS_Psurf.<date>.grb",
 Qfile_template     = "<DataDir>/Qair/GLDAS_Qair.<date>.grb",
 LWfile_template    = "<DataDir>/LWdown/GLDAS_LWdown.<date>.grb",
 SWfile_primary     = "<DataDir>/SWdown/GLDAS_SWdown.<date>.grb",
 SWfile_secondary   = "<DataDir>/SWdown/GLDAS_SWdown.<date>.grb",
 PCPfile_primary    = "<DataDir>/Precip/GLDAS_Precip.<date>.grb"
 PCPfile_secondary  = "<DataDir>/Precip/GLDAS_Precip.<date>.grb",

 WEASDfile_template = "<DataDir>/INIT/GLDAS_SWE.<date>.grb",
 CANWTfile_template = "<DataDir>/INIT/GLDAS_Canopint.<date>.grb",
 SKINTfile_template = "<DataDir>/INIT/GLDAS_AvgSurfT.<date>.grb",

 STfile_template    = "<DataDir>/INIT/GLDAS_TSoil_000-010.<date>.grb",
                      "<DataDir>/INIT/GLDAS_TSoil_010-040.<date>.grb",
                      "<DataDir>/INIT/GLDAS_TSoil_040-100.<date>.grb",
                      "<DataDir>/INIT/GLDAS_TSoil_100-200.<date>.grb",

 SMfile_template    = "<DataDir>/INIT/GLDAS_SoilM_000-010.<date>.grb",
                      "<DataDir>/INIT/GLDAS_SoilM_010-040.<date>.grb",
                      "<DataDir>/INIT/GLDAS_SoilM_040-100.<date>.grb",
                      "<DataDir>/INIT/GLDAS_SoilM_100-200.<date>.grb",



```

## Running HRLDAS

15. You are basically done now. Inside of the HRLDAS_forcing directory, run:

```
./create_forcing namelist.input.GLDAS
```
If successful, you will see a lot of output that generates the LDASIN files (formatted input files) that can be read by HRLDAS. If this step does not complete properly, it can be due to a variety of issues stemming from an improper compilation of HRLDAS in step 9, incorrectly organizing your forcing data in step 10, missing entries in your VTABLE or other issues with the GRIB files being used. 

16. Great, now we have our forcing and initialization data, we can move in to the run directory and edit the final HRLDAS namelist. This controls a variety of parameters and configurations and is left to the read to decide how they want to run the simulation. Just make sure you set the *INDIR* to the location of the LDASIN files you created in step 15 and *OUTDIR* to the location where you want to write the NoahMP output to.

17. Finally, run:

```
./hrldas.exe
```

If successful, you will get netCDF (LDASOUT) files in the *OUTDIR* you set in step 16.

18. Write an award winning paper based on your use of HRLDAS!


## Final Comments

As I previously mentioned, the most difficult part of this process is collecting and organizing your forcing data so this is most likely where you will run into an issue. If you do encounter a problem, first consult the documentation at: (https://github.com/NCAR/hrldas/tree/master/hrldas) as well as the GitHub project issue tracking center. Otherwise, feel free to reach out to me:

* **Fraser King** - fdmking@uwaterloo.ca - [frasertheking](https://github.com/frasertheking)
