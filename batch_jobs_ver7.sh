#!/bin/bash
##
## Batch FLUENT submission script for PBS on DELTA - Version 6
## ------------------------------------------------------------
## Runs multiple CFD jobs on a single node
## Supports: .jou files, .cas/.cas.h5 files, and .dat/.dat.h5 files
##
## STEP 1: Enter a job name after the -N on the line below:
##
#PBS -N fluent_batch_v6
##
## STEP 2: Select resources (adjust based on number of jobs)
##
#PBS -l select=1:ncpus=12:mpiprocs=12
##
## STEP 3: Select the correct queue
##
#PBS -q two_day
##
## STEP 4: Replace with your Cranfield email address
##
#PBS -m abe
#PBS -M spencer.matthews.397@cranfield.ac.uk
##
## ====================================
## DO NOT CHANGE THE LINES BETWEEN HERE
## ====================================
#PBS -l application=fluent
#PBS -j oe
#PBS -W sandbox=PRIVATE
#PBS -k n
ln -s $PWD $PBS_O_WORKDIR/$PBS_JOBID
## Change to working directory
cd $PBS_O_WORKDIR
## ========
## AND HERE
## ========

## STEP 5: Load modules
module use /gpfs/apps/modules/all/
module load ANSYS/2024R1

## Configuration - MODIFY THESE FOR YOUR PROJECT
PROJECT_DIR="NonPorous_NACA0012"
CORES_PER_JOB=2
SOLVER_DIMENSION="2ddp"  # 2ddp for 2D, 3ddp for 3D

# List of subdirectories to process (one job per directory)
CASE_DIRS=("AoA0" "AoA1" "AoA2" "AoA3" "AoA4" "AoA5")

LOG_DIR="${PBS_O_WORKDIR}/fluent_logs_${PBS_JOBID}"
mkdir -p "$LOG_DIR"

echo "========================================" 
echo "Batch Fluent Job Started at $(date)"
echo "Job ID: $PBS_JOBID"
echo "Node: $(hostname)"
echo "Working directory: $PBS_O_WORKDIR"
echo "Project directory: $PROJECT_DIR"
echo "Solver dimension: $SOLVER_DIMENSION"
echo "========================================"

# Function to run a single Fluent job
run_fluent_job() {
    case_dir=$1
    job_index=$2
    
    # Full path to job directory
    job_dir="${PBS_O_WORKDIR}/${PROJECT_DIR}/${case_dir}"
    
    # Check if job directory exists
    if [ ! -d "$job_dir" ]; then
        echo "ERROR: Directory $job_dir does not exist!" >> "${LOG_DIR}/job_${case_dir}.log"
        return 1
    fi
    
    echo "========================================" >> "${LOG_DIR}/job_${case_dir}.log"
    echo "Starting Fluent job for ${case_dir} at $(date)" >> "${LOG_DIR}/job_${case_dir}.log"
    echo "Working in directory: $job_dir" >> "${LOG_DIR}/job_${case_dir}.log"
    echo "========================================" >> "${LOG_DIR}/job_${case_dir}.log"
    
    # Change to job-specific directory
    cd "$job_dir" || {
        echo "ERROR: Failed to cd to $job_dir" >> "${LOG_DIR}/job_${case_dir}.log"
        return 1
    }
    
    # Create a temporary node file for this job
    job_nodefile="${job_dir}/fluent_nodes_${case_dir}.$$"
    head -n $CORES_PER_JOB $PBS_NODEFILE | sort -u > "$job_nodefile"
    
    # Determine input mode and create/use journal file
    local journal_file=""
    
    # Check for existing journal file first
    if [ -f "input.jou" ]; then
        journal_file="input.jou"
        echo "Using existing journal file: $journal_file" >> "${LOG_DIR}/job_${case_dir}.log"
    else
        # Look for .jou files
        journal_file=$(ls -1 *.jou 2>/dev/null | head -1)
        
        if [ -n "$journal_file" ]; then
            echo "Using existing journal file: $journal_file" >> "${LOG_DIR}/job_${case_dir}.log"
        else
            # No journal file - auto-detect case/data files and create journal
            echo "No journal file found - auto-generating based on case files" >> "${LOG_DIR}/job_${case_dir}.log"
            
            # Find case file
            case_file=$(ls -1 *.cas.h5 2>/dev/null | head -1)
            if [ -z "$case_file" ]; then
                case_file=$(ls -1 *.cas 2>/dev/null | head -1)
            fi
            
            if [ -z "$case_file" ]; then
                echo "ERROR: No input files found (.jou, .cas.h5, or .cas)" >> "${LOG_DIR}/job_${case_dir}.log"
                rm -f "$job_nodefile"
                cd "$PBS_O_WORKDIR"
                return 1
            fi
            
            echo "Found case file: $case_file" >> "${LOG_DIR}/job_${case_dir}.log"
            
            # Check for data file
            data_file="${case_file%.cas.h5}.dat.h5"
            if [ ! -f "$data_file" ]; then
                data_file="${case_file%.cas}.dat"
            fi
            
            # Create auto-generated journal file
            journal_file="run_${case_dir}_${PBS_JOBID}.jou"
            
            if [ -f "$data_file" ]; then
                # Data file exists - continue from previous solution
                echo "Data file found: $data_file (continuing from previous solution)" >> "${LOG_DIR}/job_${case_dir}.log"
                cat > "$journal_file" << 'JEOF'
; Auto-generated journal - continue from existing solution
/file/read-case-data
JEOF
                echo "${case_file}" >> "$journal_file"
                cat >> "$journal_file" << 'JEOF'

; Continue transient calculation
/solve/dual-time-iterate

; Save results
/file/write-case-data
JEOF
                echo "${case_file}" >> "$journal_file"
                cat >> "$journal_file" << 'JEOF'

; Exit Fluent
/exit
yes
JEOF
            else
                # No data file - initialize first
                echo "No data file found - will initialize before running" >> "${LOG_DIR}/job_${case_dir}.log"
                cat > "$journal_file" << 'JEOF'
; Auto-generated journal - initialize and run
/file/read-case
JEOF
                echo "${case_file}" >> "$journal_file"
                cat >> "$journal_file" << 'JEOF'

; Initialize the solution
/solve/initialize/initialize-flow

; Start transient calculation
/solve/dual-time-iterate

; Save results
/file/write-case-data
JEOF
                echo "${case_file}" >> "$journal_file"
                cat >> "$journal_file" << 'JEOF'

; Exit Fluent
/exit
yes
JEOF
            fi
            
            echo "Created journal file: $journal_file" >> "${LOG_DIR}/job_${case_dir}.log"
        fi
    fi
    
    # Run Fluent
    echo "Launching Fluent at $(date)" >> "${LOG_DIR}/job_${case_dir}.log"
    fluent $SOLVER_DIMENSION -ssh -g -cflush -pib -pib.ofed -t${CORES_PER_JOB} \
        -cnf="$job_nodefile" -i "$journal_file" >> "${LOG_DIR}/job_${case_dir}.log" 2>&1
    
    exit_code=$?
    
    # Clean up temporary files
    rm -f "$job_nodefile"
    
    echo "========================================" >> "${LOG_DIR}/job_${case_dir}.log"
    echo "Finished Fluent job for ${case_dir} at $(date)" >> "${LOG_DIR}/job_${case_dir}.log"
    echo "Exit code: $exit_code" >> "${LOG_DIR}/job_${case_dir}.log"
    echo "========================================" >> "${LOG_DIR}/job_${case_dir}.log"
    
    # Return to original directory
    cd "$PBS_O_WORKDIR"
    
    return $exit_code
}

export -f run_fluent_job
export LOG_DIR
export CORES_PER_JOB
export PROJECT_DIR
export PBS_O_WORKDIR
export PBS_NODEFILE
export SOLVER_DIMENSION

# Verify all case directories exist
echo "Checking case directories..."
all_dirs_exist=true
for case_dir in "${CASE_DIRS[@]}"; do
    full_path="${PBS_O_WORKDIR}/${PROJECT_DIR}/${case_dir}"
    if [ ! -d "$full_path" ]; then
        echo "WARNING: Directory $full_path does not exist!"
        all_dirs_exist=false
    else
        echo "  ✓ Found: $case_dir"
        # Check if input files exist
        file_count=$(ls -1 "$full_path"/*.jou "$full_path"/*.cas.h5 "$full_path"/*.cas 2>/dev/null | wc -l)
        if [ $file_count -eq 0 ]; then
            echo "    WARNING: No input files found (.jou, .cas.h5, or .cas)"
            all_dirs_exist=false
        fi
    fi
done

if [ "$all_dirs_exist" = false ]; then
    echo "ERROR: Not all case directories or files exist. Please check above."
    
    # Send failure email if mail is available
    if command -v mail &> /dev/null && [ -n "${PBS_M}" ]; then
        echo "Batch job ${PBS_JOBID} failed: Missing case directories or input files" | \
            mail -s "FLUENT Batch Job Failed - ${PBS_JOBID}" "${PBS_M}"
    fi
    
    rm -f $PBS_O_WORKDIR/$PBS_JOBID
    exit 1
fi

echo "All directories verified. Starting jobs..."
echo ""

# Calculate how many jobs to run in parallel based on available cores
total_cores=$(cat $PBS_NODEFILE | wc -l)
jobs_per_batch=$((total_cores / CORES_PER_JOB))
echo "Total cores available: $total_cores"
echo "Running up to $jobs_per_batch jobs in parallel (${CORES_PER_JOB} cores each)"
echo ""

# Run jobs in batches
total_jobs=${#CASE_DIRS[@]}
job_index=0
completed_jobs=0
failed_jobs=0

while [ $job_index -lt $total_jobs ]; do
    batch_end=$((job_index + jobs_per_batch))
    if [ $batch_end -gt $total_jobs ]; then
        batch_end=$total_jobs
    fi
    
    batch_size=$((batch_end - job_index))
    echo "Starting batch: jobs $((job_index + 1)) to ${batch_end} (${batch_size} jobs)..."
    
    # Launch jobs in this batch
    pids=()
    for i in $(seq $job_index $((batch_end - 1))); do
        run_fluent_job "${CASE_DIRS[$i]}" $((i + 1)) &
        pids+=($!)
    done
    
    # Wait for this batch to complete and track exit codes
    for pid in "${pids[@]}"; do
        wait $pid
        if [ $? -eq 0 ]; then
            ((completed_jobs++))
        else
            ((failed_jobs++))
        fi
    done
    
    echo "Batch complete. Progress: $completed_jobs/$total_jobs completed, $failed_jobs failed"
    echo ""
    
    job_index=$batch_end
done

echo "========================================"
echo "All Fluent jobs completed at $(date)"
echo "========================================"
echo "Summary:"
echo "  Total jobs: $total_jobs"
echo "  Completed successfully: $completed_jobs"
echo "  Failed: $failed_jobs"
echo ""
echo "Logs saved to: $LOG_DIR/"
echo "Results saved in: ${PROJECT_DIR}/*/"

# Send completion email with summary
if command -v mail &> /dev/null && [ -n "${PBS_M}" ]; then
    email_subject="FLUENT Batch Job Complete - ${PBS_JOBID}"
    if [ $failed_jobs -gt 0 ]; then
        email_subject="FLUENT Batch Job Complete (with failures) - ${PBS_JOBID}"
    fi

    cat > /tmp/job_summary_${PBS_JOBID}.txt << EMAILEOF
FLUENT Batch Job Summary
========================

Job ID: ${PBS_JOBID}
Job Name: ${PBS_JOBNAME}
Completed at: $(date)

Statistics:
-----------
Total jobs: $total_jobs
Completed successfully: $completed_jobs
Failed: $failed_jobs

Configuration:
--------------
Project Directory: ${PROJECT_DIR}
Solver Dimension: ${SOLVER_DIMENSION}
Cores per job: ${CORES_PER_JOB}

Log Directory: ${LOG_DIR}
Node(s) used: $(cat $PBS_NODEFILE | sort -u | paste -sd, -)

To view logs:
  cd ${PBS_O_WORKDIR}
  ls ${LOG_DIR}/

EMAILEOF

    if [ $failed_jobs -gt 0 ]; then
        echo "" >> /tmp/job_summary_${PBS_JOBID}.txt
        echo "Failed jobs - check these logs:" >> /tmp/job_summary_${PBS_JOBID}.txt
        for case_dir in "${CASE_DIRS[@]}"; do
            if grep -q "Exit code: [^0]" "${LOG_DIR}/job_${case_dir}.log" 2>/dev/null; then
                echo "  - ${case_dir}" >> /tmp/job_summary_${PBS_JOBID}.txt
            fi
        done
    fi

    mail -s "$email_subject" "${PBS_M}" < /tmp/job_summary_${PBS_JOBID}.txt
    rm -f /tmp/job_summary_${PBS_JOBID}.txt
fi

## Tidy up the log directory
## DO NOT CHANGE THE LINE BELOW
## ============================
rm -f $PBS_O_WORKDIR/$PBS_JOBID

exit 0
#