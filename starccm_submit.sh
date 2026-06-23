#!/bin/bash
##
## Minimal STAR-CCM+ Batch Submission Script for PBS
## --------------------------------------------------
## Runs a single .sim file on the requested resources.
## No email, no auto-generated journals, no parallel batching.
##
## STEP 1: Job name
#PBS -N AutoCFD_Case1_RESTARTjob_20260616
##
## STEP 2: Resources (nodes : cores per node : MPI procs per node)
#PBS -l select=1:ncpus=62:mpiprocs=62
##
## STEP 3: Queue
#PBS -q five_day
##
## STEP 4: Mail OFF (no notifications of any kind)
#PBS -m n
##
## ====================================
## DO NOT CHANGE THE LINES BETWEEN HERE
## ====================================
#PBS -l application=fluent
#PBS -j oe
#PBS -W sandbox=PRIVATE
#PBS -k n
ln -s $PWD $PBS_O_WORKDIR/$PBS_JOBID
cd $PBS_O_WORKDIR
## ========
## AND HERE
## ========

################################################################################
# CONFIGURATION - edit these for your run
################################################################################

# STAR-CCM+ module to load
STARCCM_MODULE="STAR-CCM+/2506_20.04.008-r8"

# License server (port@host)
LICPATH="1999@cclic-1.central.cranfield.ac.uk"

# Path to the case directory containing your .sim file (relative to submission dir)
CASE_DIR="job"

# Name of the specific .sim file to run (leave empty to auto-pick the first .sim found)
SIMFILE_NAME="20260616_SM_WindsorBody_coarse_ver2_RANS_RESTART.sim"

################################################################################
# EXECUTION
################################################################################

echo "========================================"
echo "STAR-CCM+ Batch Job"
echo "========================================"
echo "Job ID:       $PBS_JOBID"
echo "Start time:   $(date)"
echo "Working dir:  $PBS_O_WORKDIR"
echo "Case dir:     $CASE_DIR"
echo "Nodes:"
sort -u $PBS_NODEFILE | sed 's/^/  /'
echo "Total cores:  $(wc -l < $PBS_NODEFILE)"
echo "========================================"

# Make sure compute node sees the site module tree
module use /apps/modules/all/

# Debug: show what the compute node actually sees
echo "----- Module environment debug -----"
echo "Hostname:    $(hostname)"
echo "MODULEPATH:  $MODULEPATH"
echo "Available STAR-CCM+ modules on this node:"
module --ignore-cache avail STAR-CCM+ 2>&1 | sed 's/^/  /'
echo "------------------------------------"

# Load module (with --ignore-cache to dodge stale Lmod cache)
module --ignore-cache load $STARCCM_MODULE

# Confirm starccm+ is on PATH
if ! command -v starccm+ &>/dev/null; then
    echo "ERROR: starccm+ not found on PATH after module load"
    exit 1
fi
echo "Using starccm+ at: $(which starccm+)"

# Move to case directory
FULL_CASE_DIR="${PBS_O_WORKDIR}/${CASE_DIR}"
if [ ! -d "$FULL_CASE_DIR" ]; then
    echo "ERROR: Case directory not found: $FULL_CASE_DIR"
    exit 1
fi
cd "$FULL_CASE_DIR" || exit 1

# Find the .sim file
if [ -n "$SIMFILE_NAME" ]; then
    # Use the explicitly named file
    if [ ! -f "$SIMFILE_NAME" ]; then
        echo "ERROR: Specified sim file not found: $FULL_CASE_DIR/$SIMFILE_NAME"
        exit 1
    fi
    SIMFILE="$SIMFILE_NAME"
else
    # Fall back to auto-detecting the first .sim file
    SIMFILE=$(ls -1 *.sim 2>/dev/null | head -1)
    if [ -z "$SIMFILE" ]; then
        echo "ERROR: No .sim file found in $FULL_CASE_DIR"
        exit 1
    fi
fi
echo "Sim file:     $SIMFILE"

# Total cores from PBS
NCORES=$(wc -l < $PBS_NODEFILE)

# Run STAR-CCM+
echo "----------------------------------------"
echo "Launching STAR-CCM+ on $NCORES cores..."
echo "----------------------------------------"

starccm+ \
    -batch \
    -np $NCORES \
    -machinefile $PBS_NODEFILE \
    -rsh ssh \
    -licpath "$LICPATH" \
    "$SIMFILE"

EXIT_CODE=$?

echo "----------------------------------------"
echo "STAR-CCM+ finished with exit code: $EXIT_CODE"
echo "End time: $(date)"
echo "----------------------------------------"

# Cleanup
rm -f $PBS_O_WORKDIR/$PBS_JOBID

exit $EXIT_CODE
