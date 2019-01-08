#!/bin/bash 
#
# smanage.sh
# Slurm Manage, for submitting and reporting on job arrays run on slurm
#
# MIT License
# Copyright (c) 2018-2019 Erik Surface
#

#### SMANAGE_EXT_SOURCE ####
# define SMANAGE_EXT_SOURCE to add a script to parse the .err or .out files
# in the script, define a function called '_ext_handle_completed' that will be passed
# a bash list of jobs. See _ext_handle_example.
if [[ -n $SMANAGE_EXT_SOURCE ]]; then
source $SMANAGE_EXT_SOURCE
fi

#### USAGE ####

usage() {	
if [ -z $1 ]; then
    usage_general
elif [[ $1 = "config" ]]; then
    usage_config_mode
elif [[ $1 = "report" ]]; then
    usage_report_mode
elif [[ $1 = "submit" ]]; then
    usage_submit_mode
else
    usage_general
fi
}

usage_general(){
echo 'usage: smanage [FLAGS] <MODE> [MODE_ARGS]'
echo "
FLAGS:
-a|--array:  Signal that jobs to report on are from sbatch --array
-h|--help:   Show help messages. For a specific mode try, --help <MODE>
-d|--debug:  Run smanage in debug mode (performs a dry-run of slurm commands)
-v|--verbose: Print more information at each step

MODE: 
report (default): output information on jobs reported by an sacct call
submit: provided an sbatch script to to submit an array of jobs
config: Convenience function to create, reset or append to a config file

SACCT_ARGS:
Specify which sacct arguments to call using the '--sacct' flag followed
by any valid sacct arguments
They can also be passed by setting SACCT_ARGS as an environment variable 

SBATCH_ARGS:
For submit mode, specify the sbatch argument using the '--sbatch' flag followed
by any valid sbatch arguments including the sbatch submit script.
They can also be passed by setting SBATCH_ARGS as an environment variable.

SMANAGE_EXT_SOURCE:
Define the env variable SMANAGE_EXT_SOURCE to add a script to parse the .err or .out files
In the script, define a function called '_ext_handle_completed' that will be passed a bash list of jobs. See _ext_handle_example.

"
}

usage_config_mode() {
echo 'usage: smanage config 
  [--append <--config <CONFIG> [--jobids=<job_id>[,job_id,...]] ]
  [--create <--batch_name <name>> [--jobids=<job_id>[,job_id,...]] ]
  [--reset <--config <CONFIG>]
Create, reset or append job ids to a config file
'
}

usage_report_mode() {
echo 'usage: smanage report [--config <CONFIG>] [--sacct <SACCT_ARGS>]
Output the report for jobs defined by CONFIG and SACCT_ARGS
'
}

usage_submit_mode() {
echo 'usage: smanage --submit [--config <CONFIG>] [--sacct <SACCT_ARGS>] [--sbatch <SBATCH_ARGS>]
usage: smanage --submit <--batch_name <batch_name>> [--max_id <#>] [--reserve <#>] 
                        [--sacct <SACCT_ARGS>] [--sbatch <SBATCH_ARGS>]
Submit a batch of jobs to slurm.

Use either a CONFIG file or smanage --sbatch args to specify information about the batch. 
--batch_name: the name of the batch. This will be override the sbatch --job_name argument if set.
    if both are provided. Default is the name of the directory containing the batched jobs.
--max_id: the maximum job number (HINT: can be above the slurm enforced cap, MaxArraySize)
--reserve: the number of jobs to submit at a time (HINT: should be less than MaxArraySize)
'

usage_config_file
}

usage_config_file() {
echo '
Config File Options:

#SLURM MGR SUMBIT OPTIONS
BATCH_NAME=[optional name of the batch as it will appear in an sacct query]
SBATCH_ARGS=[script and its argument to run with sbatch]

RESERVE=[size of the reservation aka number of jobs allows at a time]
MAX_ID=[max job index of the array]

'
}

#### GLOBALS ####
SACCT=/usr/bin/sacct
SBATCH=/usr/bin/sbatch
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
	pretty_print_commas ${sorted[@]}
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
# 10% of runs should be good enough for an average
run_times() {
	runs=($@)

	sum_wall_time=0
	sum_elapsed=0
    
    if [[ ${#runs[@]} -gt 10000 ]]; then 
        sample_size=$((${#runs[@]} / 10 ))
    else
        sample_size=${#runs[@]}
    fi

    local idx=0
    for run in ${runs[@]}; do
        idx=$(($idx + 1))
        if [[ $idx -gt $sample_size ]]; then
            break
        fi
		IFS='|' read -ra split <<< "$run"
		submit_=$(date --date=${split[$SUBMIT_TIME]} +%s )
		start_=$(date --date=${split[$START_TIME]} +%s )
		end_=$(date --date=${split[$END_TIME]} +%s )
		sum_elapsed=$(( sum_elapsed + $(( $end_ - $start_ )) ))
		sum_wall_time=$((sum_wall_time + $(( $end_ - $submit_ )) ))
	done

	avg_elapsed=$(($sum_elapsed / $sample_size))
	avg_wall_time=$(($sum_wall_time / $sample_size))

	echo "	Avg Run Time: $(convertsecs $avg_elapsed)"
	echo "	Avg Wall Time: $(convertsecs $avg_wall_time)"
}

set_config_value() {
PARAM=$1
VALUE=$2

if [[ -n $DEBUG || $(grep $PARAM $CONFIG) ]]; then
    $DEBUG sed -i "s/${PARAM}=.*/${PARAM}=${VALUE}/" $CONFIG
else
    $DEBUG echo "${PARAM}=${VALUE}" >> $CONFIG
fi

}

#### SACCT PARSING ####
# Use SACCT to load the jobs
COMPLETED=()
FAILED=()
TIMEOUT=()
RUNNING=()
PENDING=()
OTHER=()

parse_sacct_jobs() {
   
    if [[ -n $CONFIG ]]; then
        # Set SACCT_ARGS from CONFIG
        source $CONFIG
        if [[ -n $JOB_IDS ]]; then
            SACCT_ARGS+=("--jobs=${JOB_IDS}")
        fi
        if [[ -n $BATCH_NAME ]]; then
            SACCT_ARGS+=("--name=${BATCH_NAME}")
        fi
        if [[ -n $BATCH_DATE ]]; then
            SACCT_ARGS+=("-S ${BATCH_DATE}")
        fi
    fi
   
    echo "Finding jobs using: $SACCT ${SACCT_ARGS[@]}"
    all=()
    while IFS=$'\n' read -r line; do
        all+=("$line")
    done < <($SACCT ${SACCT_ARGS[@]})

    if [[ ${#all[@]} -eq 0 ]]; then
	    echo "No jobs found with these sacct args"
    else
        if [[ ! ${SACCT_ARGS[@]} =~ "--jobs=" ]]; then
            echo "Found jobs: $(get_sorted_jobs ${all[@]})"
        fi
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
}

#### CONFIG MODE ####

append_ids() {
    if [[ -z $JOB_IDS ]]; then
        # Add the job ids env var if missing
        set_config_value "JOB_IDS" $IDS
    else
        # Add the job ids in sorted order
        JOB_IDS=$(echo $JOB_IDS,$IDS)
        JOB_IDS=$(echo $JOB_IDS | tr , "\n" | sort | uniq | tr "\n" , ; echo )
        set_config_value "JOB_IDS" $JOB_IDS
    fi

}

append_config()
{
    if [[ $# -eq 0 ]]; then
        usage "config"
        return 1
    fi

    while test $# -ne 0; do
        case $1 in
        --job_ids) shift
            if [[ -z $1 ]]; then
                usage "config"
                return 1
            fi
            IDS=$1
        ;;
        --config) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "config"
                return 1
            fi
            CONFIG=$(readlink -f $1)
        ;;
        *) usage "config"
             return 1
        ;;
        esac
        shift
    done
    append_ids $IDS
}

create_config() {
    while test $# -ne 0; do
        case $1 in
        --job_ids) shift
            JOB_IDS=$1
        ;;
        --batch_name) shift
            if [[ -z $1 ]]; then
                usage "config"
                return 1
            fi
            BATCH_NAME=$1
            ;;
        *) usage "config"
            return 1
        ;;
        esac
        shift
    done

    if [ -z $BATCH_NAME ]; then
        echo "No batch name provided"
        usage "config"
        return 1
    fi
    
    BATCH_DATE="$(date +%Y-%m-%dT%H:%M)"

echo "Creating CONFIG file ${BATCH_NAME}_CONFIG"

cat << EOT > ${BATCH_NAME}_CONFIG
BATCH_NAME=$BATCH_NAME
BATCH_DATE=$BATCH_DATE
JOB_IDS=$JOB_IDS

EOT

}

reset_config() {
    if [[ -z $1 || ! -e $1 ]]; then
       usage "config"
       return 1
    fi
    CONFIG=$(readlink -f $1)
    source $CONFIG
    
    echo "Resetting $BATCH_NAME"

    set_config_value "BATCH_DATE" ""
    set_config_value "JOB_IDS" ""
    set_config_value "NEXT_RUN_ID" ""
    set_config_value "LAST_RUN_ID" ""
 
    return 0
}

config_mode() {
    if [[ $# -eq 0 ]]; then
        usage "config"
        return 1
    fi
        
    while test $# -ne 0; do
        case $1 in
        --append) append_config ${@:2:$#-1} 
            return $?
        ;;
        --create) create_config ${@:2:$#-1}
            return $?
        ;;
        --reset) reset_config ${@:2:$#-1}
            return $?
        ;;
        *) usage "config"
            return 1
        ;;        
        esac
    done

}
    
#### REPORT MODE ####

handle_completed() {
	runs=($@)

    run_times ${runs[@]}

    if [[ -n $SMANAGE_EXT_SOURCE ]]; then
        _ext_handle_completed ${runs[@]}
    fi

    echo ""

}

handle_failed() {
    runs=($@)
	list=()	
	for run in ${runs[@]}; do
	   	IFS='|' read -ra split <<< "$run"
		list+=(${split[$JOBID]})
	done

    echo "Rerun these jobs:"
	#pretty_print_tabs ${list[@]}
    print_sorted_jobs ${list[@]}

    if [[ $VERBOSE -eq 1 ]]; then
	    if [[ -n $SMANAGE_EXT_SOURCE ]]; then
            _ext_handle_failed ${runs[@]}
        fi
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

	    #pretty_print_tabs ${list[@]}
	    #print_sorted_jobs ${list[@]}

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

report_mode() {
    local opts="--config --sacct"
    
    while test $# -ne 0; do
        case $1 in
        --config) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "report"
                return 1
            fi
            CONFIG=$(readlink -f $1)
        ;;
        --sacct) shift
            while [[ -n $1 && ! $opts =~ $1 ]]; do
                SACCT_ARGS+=($1)
                shift
            done
        ;;
        *)
            usage "report"
            return 1
        ;;        
        esac
        shift
    done
    
    parse_sacct_jobs
    
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

    return 0
}


#### SUBMIT MODE ####

submit_batch() {

    echo "Submitting jobs: $SBATCH $ARRAY_ARG $BATCH_NAME_ARG ${SBATCH_ARGS[@]}"

    if [[ -z $DEBUG ]]; then
        OUTPUT=$($SBATCH $ARRAY_ARG $BATCH_NAME_ARG ${SBATCH_ARGS[@]})
    fi

    if [[ $? -ne 0 ]]; then
        echo ERROR: $OUTPUT
        exit 1
    fi

    # read the new job number from the sbatch output
    # On success sbatch should return "Submitted batch job <job_id>"
    echo $OUTPUT
    if [[ -z $DEBUG ]]; then
        IFS=" " read -ra split <<< "$OUTPUT"
        job_id=${split[3]}
    else
        # print a blank placeholder if we are in debug mode
        job_id="<job_id>"
    fi

    # append the job id to the script if it exists
    if [[ -n $CONFIG ]]; then
        config_mode --append --config $CONFIG --job_ids $job_id
        if [[ -z $ARRAY_ARG && -n $NEXT_RUN_ID && -n $LAST_RUN_ID ]]; then
            set_config_value "NEXT_RUN_ID" $NEXT_RUN_ID
            set_config_value "LAST_RUN_ID" $LAST_RUN_ID
        fi
    fi
   
    return 0 
}

reserve_submit_batch() {
    curr_max_id=-1
    num_to_run=$RESERVE

    parse_sacct_jobs
  
    runs+=${PENDING[@]}
    runs+=${RUNNING[@]}
    runs+=${COMPLETED[@]}

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

    if [[ -n $LAST_RUN_ID ]]; then
        NEXT_RUN_ID=$(($LAST_RUN_ID + 1))
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    else
        NEXT_RUN_ID=0
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run - 1))
    fi
    if [[ $LAST_RUN_ID -gt $MAX_ID ]]; then
        LAST_RUN_ID=$MAX_ID
    fi

    if [[ $NEXT_RUN_ID -ge $MAX_ID ]]; then
       echo "All jobs for batch ${BATCH_NAME} are queued"
       return 0
    fi

    idx=$(($NEXT_RUN_ID % $MaxArraySize))
    idy=$(($LAST_RUN_ID % $MaxArraySize))
    if [[ $idx -eq $idy ]]; then
        ARRAY="$idx"
        echo "Submitting batch $BATCH_NAME job $NEXT_RUN_ID as array $ARRAY"
    else
        ARRAY="$idx-$idy"
        echo "Submitting batch $BATCH_NAME jobs $NEXT_RUN_ID-$LAST_RUN_ID as array $ARRAY"
    fi
  
    if [[ -z $ARRAY_ARG ]]; then
        ARRAY_ARG="--array=${ARRAY}"
    fi
 
    submit_batch

}

submit_batch_jobs() {
    if [[ -z $ARRAY_ARG ]] && [[ -n $RESERVE ]] && [[ -n $MAX_ID ]]; then
        # use the RESERVE and MAX_ID to run the batch
        reserve_submit_batch
    else
        echo "Submitting batch $BATCH_NAME"
        submit_batch
    fi

    return $?
}

submit_mode() {
    if [[ $# -eq 0 ]]; then
        usage "submit"
        return 1
    fi

    SBATCH_ARGS=()
    local opts="--batch_name --config --max_id --reserve --sacct --sbatch"
    while test $# -ne 0; do
        case $1 in
        --batch_name) shift
            if [[ -z $1 ]]; then
                usage "submit"
                return 1
            fi
            BATCH_NAME=$1
        ;;
        --config) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "submit"
                return 1
            fi
            CONFIG=$(readlink -f $1)
            source $CONFIG
        ;;
        --max_id) shift
            if [[ -z $1 || ! $1 =~ [[:digit:]] ]]; then
                usage "submit"
                return 1
            fi
            MAX_ID=$1
        ;;
        --reserve) shift
            if [[ -z $1 || ! $1 =~ [[:digit:]] ]]; then
                usage "submit"
                return 1
            fi
            RESERVE=$1
        ;;
        --sacct) shift
            while [[ -n $1 && ! $opts =~ $1 ]]; do
                SACCT_ARGS+=($1)
                shift
            done 
        ;;
        --sbatch) shift
            while [[ -n $1 && ! $opts =~ $1 ]]; do 
                if [[ $1 =~ "--array=" ]]; then
                    ARRAY_ARG="$1"
                else
                    SBATCH_ARGS+=($1)
                fi
                shift
            done 
        ;;      
        *)
            usage "submit"
            return 1
        ;;        
        esac
        shift
    done

    # argument post processing
    if [[ -z $BATCH_NAME ]]; then
        # find and use the --job-name from sbatch if provided
        for val in ${SBATCH_ARGS[@]}; do
            if [[ $val =~ "--job-name" ]]; then
                IFS='=' read -ra split <<< "$val"
                BATCH_NAME=${split[1]}
                break
            elif [[ $val =~ "-J" ]]; then
                shift
                BATCH_NAME=$1
                break
            fi
        done

        if [[ -z $BATCH_NAME ]]; then
            echo "No batch name provided"
            usage "submit"
            return 1
        fi
    else
        BATCH_NAME_ARG="--job-name=$BATCH_NAME"
    fi

    if [[ -z $CONFIG && -n $MAX_ID && -n $RESERVE ]]; then
        # if --max_id and --reserve where used, create a config file
        if [[ ! -e "${BATCH_NAME}_CONFIG" ]]; then
           $DEBUG config_mode --create --batch_name $BATCH_NAME
        fi        
        CONFIG=$(readlink -f "${BATCH_NAME}_CONFIG")
        SBATCH_ARGS+=("$CONFIG")
        
        set_config_value "MAX_ID" $MAX_ID
        set_config_value "RESERVE" $RESERVE
    fi

    submit_batch_jobs

    return $?

}

#### MAIN ####

DEBUG=
VERBOSE=
HELP=

# print out help if no args provided
if [[ -z $1 ]]; then
    usage
    exit 0
fi

# handle smanage options
modes="report reset submit config"
MODE=
while [[ $# -gt 0 ]]; do
    case $1 in
    -h|--help) HELP=1 ;; 
    -d|--debug) DEBUG=/usr/bin/echo ;;
    -v|--verbose) VERBOSE=1 ;;
    esac
    # the MODE must be the first parameter after opts
    if [[ $modes =~ $1 ]]; then
       MODE=$1
       break
    fi
    shift
done

if [[ -n $HELP ]]; then
    usage "$MODE"
    exit 0
fi

# the remaining arguments get passed whichever MODE is specified
case "$MODE" in
    config) config_mode ${@:2:$#-1} ;;
    report) report_mode ${@:2:$#-1} ;;
    reset)  reset_mode  ${@:2:$#-1} ;;
    submit) submit_mode ${@:2:$#-1} ;;
    *) usage ;; 
esac
exit $?

# vim: sw=4:ts=4:expandtab
