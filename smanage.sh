#!/bin/bash 
#
# smanage.sh
# Slurm Manage, for submitting and reporting on job arrays run on slurm
#
# MIT License
# Copyright (c) 2018 Erik Surface
#

#### USAGE ####

usage() {	
echo "usage: $0 <MODE> [FLAGS] [SACCT_ARGS]"
echo 'MODE:
--report: (default) output information on jobs reported by an sacct call
--submit: provided an sbatch script to to submit an array of jobs
--config: create a config file
--reset: reset the config file to start job submittion from job 0
For more information: smanage --help <MODE>'  
echo 'FLAGS:
--array: Flag to signal that jobs to report on are from sbatch --array
--debug: dry-run whichever commands are input
--verbose: Add this flag to see more information
'
echo 'SACCT_ARGS: 
Add arguments for sacct passing arguments after smanage args
They can also be passed by setting SACCT_ARGS as an environment variable 
'
}

usage_create_config() {
echo "usage: $0 --config <job_name> [job_id,[job_id,...]]
Creates <job_name>_report_config file
"

}

usage_reset() {
echo "usage: $0 --reset <config>
Reset the <config> file to start fresh
"

}

usage_report() {
echo "usage: $0 --report [config]
"
}

usage_submit() {
echo "usage: $0 --submit <config>
      usage: $0 --submit <<--batch_name <batch_name>> <--batch_dir <batch_dir>> 
                          <--batch_prefix> <batch_prefix>>>
                         [--max_id <#>] [--reserve <#>] [--array <#-#>]
                         [--reservation <reservation>] [--partition <partition>]
    
Config File Options:

#SLURM MGR SUMBIT OPTIONS
BATCH_DIR=[directory where the batch of jobs is stored]
BATCH_PREFIX=[the prefix name for the batch set]
BATCH_NAME=[optional name of the batch as it will appear in an sacct query]
BATCH_SCRIPT=[sbatch script to run]

RESERVE=[size of the reservation aka number of jobs allows at a time]
MAX_ID=[max job index of the array]
ARRAY=[#-# jobs to run]

# SBATCH OPTIONS
PARTITION=[which partition to submit to]
RESERVATION=[targeted set of nodes]
"
}

#### SMANAGE_EXT_SOURCE ####
# define SMANAGE_EXT_SOURCE to add a script to parse the .err or .out files
# in the script, define a function called '_ext_handle_completed' that will be passed
# a bash list of jobs. See _ext_handle_example.
# the 'smanage --job_dir' must be provided
if [[ -n $SMANAGE_EXT_SOURCE ]]; then
source $SMANAGE_EXT_SOURCE
fi

#### GLOBALS ####
SACCT=/usr/bin/sacct
MaxArraySize=$(/usr/bin/scontrol show config | sed -n '/^MaxArraySize/s/.*= *//p')

# Required SACCT arguments and idexes to them
SACCT_ARGS+=("-XP --noheader") 
export SACCT_FORMAT='jobid,state,partition,submit,start,end,jobidraw'
JOBID=0			# get the jobid from jobid_jobstep
JOBSTEP=1		# get the jobstep from jobid_jobstep
JOBSTATE=1		# Job state
PARTITION=2		# Where is the job running?
SUBMIT_TIME=3		# Submit time
START_TIME=4		# Start time
END_TIME=5		# End time

#### Helper funtions for printing ####

# print a tab separated list of jobs in five columns	
pretty_print_tabs() {
	list=($@)
	
	count=1
	mod=5
	for l in ${list[@]}; do
		printf "\t$l"
		if (( $count % $mod == 0 )); then
			printf "\n"
		fi
		((count+=1))
	done
	printf "\n"
}

# print a comma separated list of jobs
# helpful for knowing which jobs to rerun
pretty_print_commas() {
	list=($@)

	count=0
	for l in ${list[@]}; do
		printf "$l"
		((count+=1))
		if (( $count < ${#list[@]} )); then
			printf ","
		fi
	done
	printf "\n"
}

# sort and print a list of jobs
print_sorted_jobs() {
	list=($@)

    sorted=( $(
		for l in ${list[@]}; do
			IFS='_' read -ra split <<< "$l"
			echo ${split[1]}
		done | sort -nu
		) )
	pretty_print_commas ${sorted[@]}
}

# get the list of jobs
get_sorted_jobs() {
	runs=($@)

	list=()
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		jobid=${split[$JOBID]}
		list+=($jobid)
	done

    sorted=( $(
		for l in ${list[@]}; do
			IFS='_' read -ra split <<< "$l"
			echo ${split[0]}
		done | sort -nu
		) )
}

# convert value of seconds to a time
convertsecs() {
	((h=${1}/3600))
	((m=(${1}%3600)/60))
	((s=${1}%60))
	printf "%02d:%02d:%02d\n" $h $m $s
}

# use the SUBMIT, START, and END times from sacct to calculate
# the average wall time and run time for a set of jobs
run_times() {
	runs=($@)

	sum_wall_time=0
	sum_elapsed=0
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		submit_=$(date --date=${split[$SUBMIT_TIME]} +%s )
		start_=$(date --date=${split[$START_TIME]} +%s )
		end_=$(date --date=${split[$END_TIME]} +%s )
		sum_elapsed=$(( sum_elapsed + $(( $end_ - $start_ )) ))
		sum_wall_time=$((sum_wall_time + $(( $end_ - $submit_ )) ))
	done

	avg_elapsed=$(($sum_elapsed / ${#runs[@]}))
	avg_wall_time=$(($sum_wall_time / ${#runs[@]}))

	echo "	Avg Run Time: $(convertsecs $avg_elapsed)"
	echo "	Avg Wall Time: $(convertsecs $avg_wall_time)"
}


#### Run State handler functions ####

handle_completed() {
	runs=($@)

	if [ $VERBOSE -eq 1 ]; then
	run_times ${runs[@]}
	    if [[ -n SMANAGE_EXT_SOURCE ]]; then
                _ext_handle_completed ${runs[@]}
            fi
	echo ""
	fi	
	
}

handle_failed() {
	runs=($@)

	output_dir=$WORK_DIR
	prefix=batch_

	list=()
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		jobid=${split[$JOBID]}
		list+=($jobid)
	
		if [ $VERBOSE -eq 1 ]; then
			output_errs="$output_dir/$prefix$jobid.err"
			printf "	Job $jobid Failed:\t"
			if [ -e $output_errs ]; then
				echo "	$(cat $output_errs)"
			else
				echo "	Output removed"
			fi
		fi
	done

	echo "Rerun these jobs:"
	if [ $JOBARRAY -eq 1 ]; then
		print_sorted_jobs ${list[@]}
	else
		pretty_print_tabs ${list[@]}
	fi

	echo ""
}

handle_running() {
	runs=($@)

	if [ $VERBOSE -eq 1 ]; then
	list=()	
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		list+=(${split[$JOBID]})
	done

	#echo "Running jobs: "
	#if [ $JOBARRAY -eq 1 ]; then
	#	print_sorted_jobs ${list[@]}
	#else
	#	pretty_print_tabs ${list[@]}
	#fi

	echo ""
	fi
}

handle_pending() {
	runs=($@)

	list=()
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		list+=(${split[$JOBID]})
	done

	if [ $VERBOSE -eq 1 ]; then
	    echo "Pending jobs: "
	    pretty_print_tabs ${list[@]}
	fi

	echo ""
}

handle_other() {
	runs=($@)

	list=()	
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		jobid=${split[$JOBID]}
		state=${split[$JOBSTATE]}
		list+=("$jobid: $state")
	done
	pretty_print_tabs ${list[@]}
}

#### REPORT MODE ####

run_batch_report() {
echo "${#COMPLETED[@]} COMPLETED jobs"
if [[ ${#COMPLETED[@]} > 0 && $VERBOSE -eq 1 ]]; then
    handle_completed ${COMPLETED[@]}
fi

echo "${#FAILED[@]} FAILED jobs"
if [[ ${#FAILED[@]} > 0 && $VERBOSE -eq 1 ]]; then
	handle_failed ${FAILED[@]}
fi

echo "${#TIMEOUT[@]} TIMEOUT jobs"
if [[ ${#TIMEOUT[@]} > 0 && $VERBOSE -eq 1 ]]; then
    handle_failed ${TIMEOUT[@]}
fi

echo "${#RUNNING[@]} RUNNING jobs"
if [[ ${#RUNNING[@]} > 0 && $VERBOSE -eq 1 ]]; then
    handle_running ${RUNNING[@]}
fi

echo "${#PENDING[@]} PENDING jobs"
if [[ ${#PENDING[@]} > 0 && $VERBOSE -eq 1 ]]; then
    handle_pending ${PENDING[@]}
fi

if [[ ${#OTHER[@]} > 0 ]]; then
	echo "${#OTHER[@]} jobs with untracked status"
	if [[ $VERBOSE -eq 1 ]]; then
		handle_other ${OTHER[@]}
	fi
fi
}

#### RESET MODE ####

reset_job() {

echo "Resetting $BATCH_NAME"

if [[ $VERBOSE -eq 1 ]]; then
    $DEBUG rm -rf $BATCH_DIR/*.sh $BATCH_DIR/output/*
fi

$DEBUG sed -i "s/JOB_IDS=.*/JOB_IDS=/" $CONFIG
$DEBUG sed -i "s/JOB_DATE=.*/JOB_DATE=/" $CONFIG

}

#### SUBMIT MODE ####

set_config_value() {
PARAM=$1
VALUE=$2

if [[ $(grep $PARAM $CONFIG) ]]; then
    $DEBUG sed -i "s/${PARAM}=.*/${PARAM}=${VALUE}/" $CONFIG
else
    $DEBUG echo "${PARAM}=${VALUE}" >> $CONFIG
fi

}

submit_batch() {
    echo "Submitting jobs $NEXT_RUN_ID - $LAST_RUN_ID as $ARRAY"
    if [[ -n $CONFIG ]]; then
        config_arg="--config $CONFIG"
    fi
    
    ARRAY=$ARRAY JOB_NAME=$BATCH_NAME NEXT_RUN_ID=$NEXT_RUN_ID $SMANAGE_SUBMIT_BATCH_SCRIPT $config_arg
    if [[ $? -eq 0 ]]; then
        if [[ -n $NEXT_RUN_ID ]]; then
            set_config_value "NEXT_RUN_ID" $NEXT_RUN_ID
            set_config_value "LAST_RUN_ID" $LAST_RUN_ID
        fi
    fi
}

reserve_submit_batch() {
  curr_max_id=-1
  num_to_run=$RESERVE

  runs+=${PENDING[@]}
  runs+=${RUNNING[@]}
  runs+=${COMPLETED[@]}

  if [[ ${#runs[@]} -gt 0 ]]; then

    num_pending=0
    for run in ${runs[@]}; do
        IFS='|' read -ra split <<< "$run"
        IFS='_' read -ra job <<< "${split[$JOBID]}"
        jobstep=${job[$JOBSTEP]}
        # Pending jobs may look like [###-###]
       if [[ $jobstep =~ ^(\[)([[:digit:]]+)-([[:digit:]]+)(\])$ ]]; then
            # Get how many are pending
            leftjobstep=( $(echo "$jobstep" | tr -d '[[:alpha:]]' | cut -d '-' -f 1) )
            rightjobstep=( $(echo "$jobstep" | tr -d '[[:alpha:]]' | cut -d '-' -f 2) )
            num_pending=$((num_pending + rightjobstep - leftjobstep))
            # Get the right-hand value from the pending job list
            jobstep=$rightjobstep
        fi
        if [[ $jobstep -gt $curr_max_id ]]; then
           curr_max_id=$jobstep
        fi
    done
    
    # use queued runs to calculate the next array of runs
    num_queued=$((${#RUNNING[@]} + num_pending))
    num_to_run=$(($RESERVE - $num_queued))

    if [[ $num_to_run -lt 1 ]]; then
        echo "No jobs submitted for ${BATCH_NAME}. The queue is full with $num_queued of $RESERVE runs"
        return 0
    fi 

    if [[ -n $USE_SARRAY_IDS ]]; then
        NEXT_RUN_ID=$(($curr_max_id + 1))
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    elif [[ -n $LAST_RUN_ID ]]; then
        NEXT_RUN_ID=$(($LAST_RUN_ID + 1))
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    else
        NEXT_RUN_ID=0
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    fi
    if [[ $LAST_RUN_ID -gt $MAX_ID ]]; then
        LAST_RUN_ID=$MAX_ID
    fi

    if [[ $NEXT_RUN_ID -ge $MAX_ID ]]; then
        echo "Ding! Jobs named ${BATCH_NAME} are done!"
        /usr/bin/crontab -r
        return 0
    fi

    if [[ -n $USE_SARRAY_IDS ]]; then
        idx=$(($NEXT_RUN_ID % $MaxArraySize))
        idy=$(($LAST_RUN_ID % $MaxArraySize))
        if [[ $idx -eq $idy ]]; then
            ARRAY="$idx"
        else
            ARRAY="$idx-$idy"
        fi
    else
        if [[ $num_to_run -eq 1 ]]; then
            ARRAY="0"
        else
	        ARRAY="0-${num_to_run}"
        fi
    fi
  fi
    
  submit_batch
}

submit_batch_jobs() {

    # ARRAY is defined -- immediately run the batch
    if [[ -n $ARRAY ]]; then
        echo array is $ARRAY
        submit_batch
    elif [[ -n $RESERVE ]] && [[ -n $MAX_ID ]]; then
       reserve_submit_batch
    fi

    return $?
}

#### MAIN ####

JOBARRAY=
DEBUG=
WORK_DIR=$PWD
VERBOSE=0
while test $# -gt 0
do
    case "$1" in
        --array)
            JOBARRAY=1
            ;;
        --config)
	    shift
            if [[ -n $1 ]] && [[ -e $1 ]]; then
                CONFIG=$(readlink -f $1)
            else
                CONFIG=$(readlink -f $1)
            else
                usage
                exit 1
            fi
            ;;
        --dir)
            shift
            if [ -z $1 ]; then
                usage
                exit 1
            fi
            WORK_DIR=$1
            ;;
        --debug)
            # test commands by printing them
            DEBUG=/usr/bin/echo
            ;;
        --exclude)
            shift
            if [ -z $1 ]; then
                usage
                exit 1
            fi
            EXCLUDE=1
            IFS=',' read -ra EXCLUDED <<< "$1"
            ;;
        -h|--help)
            shift
            if [ -z $1 ]; then
                usage
            elif [[ $1 = "config" ]]; then
                usage_config
            elif [[ $1 = "report" ]]; then
                usage_report
            elif [[ $1 = "reset" ]]; then
                usage_reset
            elif [[ $1 = "submit" ]]; then
                usage_submit
            else
                usage
            fi
            exit 0
            ;;
        --list)
            LIST=1
            ;;
        --reset)
            RESET=1
            ;;
        --submit)
            SUBMIT=1
            ;;
        --verbose) 	
            VERBOSE=1
            ;;
        *)
            SACCT_ARGS+=($1)
            ;;
    esac
    shift
done

if [[ -n $RESET ]]; then
    if [[ -z $CONFIG || ! -e $CONFIG ]]; then
        echo "No config file provided for --reset. Add --config <config>"
       exit 1
    fi
    source $CONFIG
    reset_job
    exit 0
fi

# Set SACCT_ARGS from CONFIG
if [[ -n $CONFIG ]]; then
    source $CONFIG
    if [[ -n $JOB_IDS ]]; then
        SACCT_ARGS+=("--jobs=${JOB_IDS}")
    fi
    if [[ -n $BATCH_NAME ]]; then
        SACCT_ARGS+=("--name=${BATCH_NAME}")
    fi
    if [[ -n $JOB_DATE ]]; then
        SACCT_ARGS+=("-S ${JOB_DATE}")
    fi
fi

# Use SACCT to load the jobs
COMPLETED=()
FAILED=()
TIMEOUT=()
RUNNING=()
PENDING=()
OTHER=()

echo "Finding jobs using: $SACCT ${SACCT_ARGS[@]}"
all=($($SACCT ${SACCT_ARGS[@]}))
if [[ ${#all[@]} -eq 0 ]]; then
	echo "No jobs found with these sacct args"
else
    echo "Jobs: $(get_sorted_jobs ${all[@]})"
fi

# Split the job list by STATE
for run in ${all[@]}; do
	IFS='|' read -ra split <<< "$run" # split the sacct line by '|'
    state=${split[$JOBSTATE]}
    if [[ $EXCLUDE -eq 1 ]]; then
        # don't process excluded jobs
		IFS='_' read -ra job <<< "${split[$JOBID]}"
	    jobid=${job[$JOBID]}
		if [[ "${EXCLUDED[@]}" =~ "${jobid}" ]]; then
			continue
		fi
	fi

    if [[ $state = "COMPLETED" ]]; then
        COMPLETED+=($run)
    elif [[ $state = "FAILED" ]]; then
        FAILED+=($run)
    elif [[ $state = "TIMEOUT" ]]; then
        TIMEOUT+=($run)
    elif [[ $state = "RUNNING" ]]; then
        RUNNING+=($run)
    elif [[ $state = "PENDING" ]]; then
        PENDING+=($run)
    else
        OTHER+=($run)
    fi

done

if [[ -n $SUBMIT ]]; then
    if [[ -z $SMANAGE_SUBMIT_BATCH_SCRIPT ]]; then
        echo "Missing sbatch script."
        usage_submit
        exit 1
    fi

    submit_batch_jobs
    exit $?
fi

run_batch_report

exit 0
