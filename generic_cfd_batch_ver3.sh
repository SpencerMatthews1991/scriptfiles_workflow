#!/bin/bash
##
## Generic CFD Batch Submission Script for PBS
## --------------------------------------------
## Works with: Fluent, OpenFOAM, CFX, Star-CCM+, SU2, etc.
##
## STEP 1: Enter a job name
##
#PBS -N cfd_batch_job
##
## STEP 2: Select resources
##
#PBS -l select=1:ncpus=12:mpiprocs=12
##
## STEP 3: Select queue/walltime
##
#PBS -q two_day
##
## STEP 4: Email address
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
cd $PBS_O_WORKDIR
## ========
## AND HERE
## ========

################################################################################
# CONFIGURATION SECTION - MODIFY THIS FOR YOUR CFD SOLVER
################################################################################

# Solver type: "fluent", "openfoam", "cfx", "starccm", "su2", "custom"
SOLVER="fluent"

# Fluent-specific settings
FLUENT_SIMULATION_TYPE="transient"  # "steady", "transient", or "" (use case settings)
FLUENT_NUM_STEPS="1200000"          # Number of iterations/time-steps, or "" (use case settings)
FLUENT_DIMENSION="2ddp"             # 2ddp, 3ddp, 2d, 3d

# Project directory containing case subdirectories
PROJECT_DIR="NonPorous_NACA0012"

# List of case directories to run
CASE_DIRS=("AoA0" "AoA1" "AoA2" "AoA3" "AoA4" "AoA5")

# Cores per job
CORES_PER_JOB=2

# Modules to load (space-separated)
MODULES="ANSYS/2024R1"

# Module path (leave empty if not needed)
MODULE_PATH="/gpfs/apps/modules/all/"

################################################################################
# SOLVER-SPECIFIC COMMANDS
################################################################################

# Function to set up solver-specific commands
setup_solver() {
    local solver=$1
    
    case $solver in
        fluent)
            SOLVER_EXECUTABLE="fluent"
            SOLVER_ARGS="-ssh -g -cflush -pib -pib.ofed"
            INPUT_FILE="input.jou"
            ;;
            
        openfoam)
            SOLVER_EXECUTABLE="simpleFoam"  # or pimpleFoam, icoFoam, etc.
            SOLVER_ARGS="-parallel"
            INPUT_FILE="system/controlDict"
            ;;
            
        cfx)
            SOLVER_EXECUTABLE="cfx5solve"
            SOLVER_ARGS="-batch"
            INPUT_FILE="*.def"
            ;;
            
        starccm)
            SOLVER_EXECUTABLE="starccm+"
            SOLVER_ARGS="-batch -power -podkey <your_key>"
            INPUT_FILE="*.sim"
            ;;
            
        su2)
            SOLVER_EXECUTABLE="SU2_CFD"
            SOLVER_ARGS=""
            INPUT_FILE="*.cfg"
            ;;
            
        custom)
            # Define your custom solver here
            SOLVER_EXECUTABLE="your_solver"
            SOLVER_ARGS="your_args"
            INPUT_FILE="your_input_file"
            ;;
            
        *)
            echo "ERROR: Unknown solver type: $solver"
            exit 1
            ;;
    esac
}

# Function to run solver for a specific case
run_solver_case() {
    local case_dir=$1
    local solver=$2
    local cores=$3
    local job_dir="${PBS_O_WORKDIR}/${PROJECT_DIR}/${case_dir}"
    
    # Check if job directory exists
    if [ ! -d "$job_dir" ]; then
        echo "ERROR: Directory $job_dir does not exist!"
        return 1
    fi
    
    cd "$job_dir" || {
        echo "ERROR: Failed to cd to $job_dir"
        return 1
    }
    
    case $solver in
        fluent)
            # Create node file
            local nodefile="${job_dir}/fluent_nodes.$$.txt"
            head -n $cores $PBS_NODEFILE | sort -u > "$nodefile"
            
            # Check for journal file first
            local input=$(find . -maxdepth 1 -name "*.jou" | head -1)
            
            if [ -n "$input" ]; then
                # Use existing journal file
                echo "Using journal file: $input"
                fluent $FLUENT_DIMENSION $SOLVER_ARGS -t${cores} \
                    -cnf="$nodefile" -i "$input"
            else
                # No journal file - create one based on available case files
                local casefile=$(ls -1 *.cas.h5 2>/dev/null | head -1)
                if [ -z "$casefile" ]; then
                    casefile=$(ls -1 *.cas 2>/dev/null | head -1)
                fi
                
                if [ -z "$casefile" ]; then
                    echo "ERROR: No input files found (.jou, .cas.h5, or .cas)"
                    rm -f "$nodefile"
                    return 1
                fi
                
                local datafile="${casefile%.cas.h5}.dat.h5"
                if [ ! -f "$datafile" ]; then
                    datafile="${casefile%.cas}.dat"
                fi
                
                # Create journal file
                input="run_auto_$$.jou"
                
                if [ -f "$datafile" ]; then
                    # Case + Data exists - continue from previous
                    echo "Creating journal to continue from: $casefile + $datafile"
                    
                    if [ -n "$FLUENT_SIMULATION_TYPE" ] && [ -n "$FLUENT_NUM_STEPS" ]; then
                        # User specified simulation type and steps
                        if [ "$FLUENT_SIMULATION_TYPE" = "transient" ]; then
                            cat > "$input" << EOF
; Auto-generated journal - continue transient simulation
/file/read-case-data
${casefile}

; Continue transient calculation for ${FLUENT_NUM_STEPS} time steps
/solve/dual-time-iterate ${FLUENT_NUM_STEPS}

; Save results
/file/write-case-data
${casefile}
yes

; Exit
/exit
yes
EOF
                        else
                            cat > "$input" << EOF
; Auto-generated journal - continue steady-state simulation
/file/read-case-data
${casefile}

; Continue steady-state calculation for ${FLUENT_NUM_STEPS} iterations
/solve/iterate ${FLUENT_NUM_STEPS}

; Save results
/file/write-case-data
${casefile}
yes

; Exit
/exit
yes
EOF
                        fi
                    else
                        # Use case file settings - just start solving
                        cat > "$input" << EOF
; Auto-generated journal - continue using case file settings
/file/read-case-data
${casefile}

; Solve using settings from case file
/solve/iterate

; Save results
/file/write-case-data
${casefile}
yes

; Exit
/exit
yes
EOF
                    fi
                else
                    # Case only - initialize first
                    echo "Creating journal to initialize and run: $casefile"
                    
                    if [ -n "$FLUENT_SIMULATION_TYPE" ] && [ -n "$FLUENT_NUM_STEPS" ]; then
                        # User specified simulation type and steps
                        if [ "$FLUENT_SIMULATION_TYPE" = "transient" ]; then
                            cat > "$input" << EOF
; Auto-generated journal - initialize and run transient
/file/read-case
${casefile}

; Initialize
/solve/initialize/initialize-flow

; Start transient calculation for ${FLUENT_NUM_STEPS} time steps
/solve/dual-time-iterate ${FLUENT_NUM_STEPS}

; Save results
/file/write-case-data
${casefile}
yes

; Exit
/exit
yes
EOF
                        else
                            cat > "$input" << EOF
; Auto-generated journal - initialize and run steady-state
/file/read-case
${casefile}

; Initialize
/solve/initialize/initialize-flow

; Start steady-state calculation for ${FLUENT_NUM_STEPS} iterations
/solve/iterate ${FLUENT_NUM_STEPS}

; Save results
/file/write-case-data
${casefile}
yes

; Exit
/exit
yes
EOF
                        fi
                    else
                        # Use case file settings
                        cat > "$input" << EOF
; Auto-generated journal - initialize and run using case file settings
/file/read-case
${casefile}

; Initialize
/solve/initialize/initialize-flow

; Solve using settings from case file
/solve/iterate

; Save results
/file/write-case-data
${casefile}
yes

; Exit
/exit
yes
EOF
                    fi
                fi
                
                echo "Created journal file: $input"
                
                # Run Fluent with auto-generated journal
                fluent $FLUENT_DIMENSION $SOLVER_ARGS -t${cores} \
                    -cnf="$nodefile" -i "$input"
                
                rm -f "$input"
            fi
            
            rm -f "$nodefile"
            ;;
            
        openfoam)
            # Check if case is decomposed
            if [ ! -d "processor0" ]; then
                echo "Decomposing case..."
                decomposePar -force > decompose.log 2>&1
            fi
            
            # Run solver
            mpirun -np $cores $SOLVER_EXECUTABLE $SOLVER_ARGS
            
            # Reconstruct if needed
            if [ -d "processor0" ]; then
                reconstructPar -latestTime > reconstruct.log 2>&1
            fi
            ;;
            
        cfx)
            # Find definition file
            local deffile=$(ls -1 *.def 2>/dev/null | head -1)
            if [ -z "$deffile" ]; then
                echo "ERROR: No .def file found"
                return 1
            fi
            
            # Run CFX
            cfx5solve -def "$deffile" -par-dist $cores $SOLVER_ARGS
            ;;
            
        starccm)
            # Find simulation file
            local simfile=$(ls -1 *.sim 2>/dev/null | head -1)
            if [ -z "$simfile" ]; then
                echo "ERROR: No .sim file found"
                return 1
            fi
            
            # Run STAR-CCM+
            starccm+ -np $cores $SOLVER_ARGS "$simfile"
            ;;
            
        su2)
            # Find config file
            local cfgfile=$(ls -1 *.cfg 2>/dev/null | head -1)
            if [ -z "$cfgfile" ]; then
                echo "ERROR: No .cfg file found"
                return 1
            fi
            
            # Run SU2
            mpirun -np $cores SU2_CFD "$cfgfile"
            ;;
            
        custom)
            # Implement your custom solver execution
            echo "Running custom solver..."
            mpirun -np $cores $SOLVER_EXECUTABLE $SOLVER_ARGS
            ;;
    esac
    
    return $?
}

################################################################################
# MAIN EXECUTION
################################################################################

LOG_DIR="${PBS_O_WORKDIR}/logs_${PBS_JOBID}"
mkdir -p "$LOG_DIR"

echo "========================================"
echo "Generic CFD Batch Job Started"
echo "========================================"
echo "Job ID: $PBS_JOBID"
echo "Start time: $(date)"
echo "Solver: $SOLVER"
echo "Working directory: $PBS_O_WORKDIR"
echo "Project directory: $PROJECT_DIR"
echo "Nodes: $(cat $PBS_NODEFILE | sort -u)"
echo "Total cores: $(cat $PBS_NODEFILE | wc -l)"
if [ "$SOLVER" = "fluent" ]; then
    echo "Simulation type: $FLUENT_SIMULATION_TYPE"
    echo "Steps: $FLUENT_NUM_STEPS"
fi
echo "========================================"

# Load modules
if [ -n "$MODULE_PATH" ]; then
    module use "$MODULE_PATH"
fi

for mod in $MODULES; do
    echo "Loading module: $mod"
    module load $mod
done

# Set up solver configuration
setup_solver $SOLVER

# Export variables for use in subshells
export -f run_solver_case
export LOG_DIR CORES_PER_JOB PROJECT_DIR PBS_O_WORKDIR PBS_NODEFILE
export FLUENT_DIMENSION FLUENT_SIMULATION_TYPE FLUENT_NUM_STEPS SOLVER_ARGS

# Verify case directories
echo ""
echo "Verifying case directories..."
all_exist=true
for case_dir in "${CASE_DIRS[@]}"; do
    full_path="${PBS_O_WORKDIR}/${PROJECT_DIR}/${case_dir}"
    if [ ! -d "$full_path" ]; then
        echo "  ERROR: $case_dir not found"
        all_exist=false
    else
        echo "  ✓ Found: $case_dir"
    fi
done

if [ "$all_exist" = false ]; then
    echo "ERROR: Not all case directories exist"
    exit 1
fi

# Calculate parallel execution strategy
total_cores=$(cat $PBS_NODEFILE | wc -l)
jobs_per_batch=$((total_cores / CORES_PER_JOB))

echo ""
echo "Execution strategy:"
echo "  Cores per job: $CORES_PER_JOB"
echo "  Jobs per batch: $jobs_per_batch"
echo "  Total jobs: ${#CASE_DIRS[@]}"
echo ""

# Execute jobs in batches
total_jobs=${#CASE_DIRS[@]}
job_index=0
completed=0
failed=0

while [ $job_index -lt $total_jobs ]; do
    batch_end=$((job_index + jobs_per_batch))
    if [ $batch_end -gt $total_jobs ]; then
        batch_end=$total_jobs
    fi
    
    batch_size=$((batch_end - job_index))
    echo "Starting batch: jobs $((job_index + 1)) to $batch_end ($batch_size jobs)"
    
    # Launch jobs in this batch
    pids=()
    for i in $(seq $job_index $((batch_end - 1))); do
        case_dir="${CASE_DIRS[$i]}"
        (
            echo "=======================================" > "${LOG_DIR}/${case_dir}.log"
            echo "Job: $case_dir" >> "${LOG_DIR}/${case_dir}.log"
            echo "Started: $(date)" >> "${LOG_DIR}/${case_dir}.log"
            echo "=======================================" >> "${LOG_DIR}/${case_dir}.log"
            
            run_solver_case "$case_dir" "$SOLVER" "$CORES_PER_JOB" \
                >> "${LOG_DIR}/${case_dir}.log" 2>&1
            
            exit_code=$?
            
            echo "=======================================" >> "${LOG_DIR}/${case_dir}.log"
            echo "Finished: $(date)" >> "${LOG_DIR}/${case_dir}.log"
            echo "Exit code: $exit_code" >> "${LOG_DIR}/${case_dir}.log"
            echo "=======================================" >> "${LOG_DIR}/${case_dir}.log"
            
            exit $exit_code
        ) &
        pids+=($!)
    done
    
    # Wait for batch completion
    for pid in "${pids[@]}"; do
        wait $pid
        if [ $? -eq 0 ]; then
            ((completed++))
        else
            ((failed++))
        fi
    done
    
    echo "Batch complete. Progress: $completed/$total_jobs completed, $failed failed"
    echo ""
    
    job_index=$batch_end
done

# Summary
echo "========================================"
echo "All Jobs Complete"
echo "========================================"
echo "End time: $(date)"
echo "Total: $total_jobs"
echo "Completed: $completed"
echo "Failed: $failed"
echo "Logs: $LOG_DIR"
echo "========================================"

# Email summary
if command -v mail &> /dev/null && [ -n "${PBS_M}" ]; then
    cat > /tmp/summary_${PBS_JOBID}.txt << EOF
CFD Batch Job Summary
=====================

Job ID: ${PBS_JOBID}
Solver: ${SOLVER}
Completed: $(date)

Statistics:
-----------
Total jobs: $total_jobs
Completed: $completed
Failed: $failed

Logs: ${LOG_DIR}/

EOF

    if [ $failed -gt 0 ]; then
        echo "Failed cases:" >> /tmp/summary_${PBS_JOBID}.txt
        for case_dir in "${CASE_DIRS[@]}"; do
            if grep -q "Exit code: [^0]" "${LOG_DIR}/${case_dir}.log" 2>/dev/null; then
                echo "  - $case_dir" >> /tmp/summary_${PBS_JOBID}.txt
            fi
        done
    fi

    mail -s "CFD Batch Job Complete - ${PBS_JOBID}" "${PBS_M}" < /tmp/summary_${PBS_JOBID}.txt
    rm -f /tmp/summary_${PBS_JOBID}.txt
fi

# Cleanup
rm -f $PBS_O_WORKDIR/$PBS_JOBID

exit 0