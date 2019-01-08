# smanage

Slurm Manage, for submitting and reporting on job arrays run on slurm

The script manages jobs running on a compute cluster that uses the [SLURM scheduler](https://slurm.schedmd.com/). 
It was developed in bash to take advantage of the automatic output from the [slurm programs available on the command line](https://slurm.schedmd.com/pdfs/summary.pdf), namely sacct and sbatch. As a key feature, smanage enables the user to submit and track large batches of jobs beyond the MaxArraySize limit set by slurm. 

## What is a job array?

If you are used to submitting jobs on a SLURM cluster, you are probably used to the
standard sbatch command:

```bash
$ sbatch myanalysis.job
```

If you are like me, you've probably written some kind of Python/R/Bash or other
script that loops through some set of variables and programmatically
generates and/or submits job files. [Here is an example](https://github.com/vsoch/image-comparison-thresholding/blob/master/preprocessing/run_make_group_maps.py#L19).
of some of the nonsense that I (contributor @vsoch) went through in graduate school.
If only I had known about job arrays!

> a job array lets you submit a ton of similar jobs using a template script.

Actually, it's just another SBATCH header. It looks like this:

```bash
#A job array with index values of 1, 2, 5, 19, 27:
#SBATCH --array=1,2,5,19,27
```

How would we use this? Let's start with a simple example, and say that we have
100 text files to process. We have them in a folder, and they are labeled 
cookie1.txt through cookie100.txt. We could use arrays to process these files
without any extraneous for loops:

```bash
#!/bin/bash
#SBATCH -J cookies-job # A single job name for the array
#SBATCH -n 1 # One Core
#SBATCH -N 1 # All cores on one machine
#SBATCH -p owners # Partition name
#SBATCH --mem 2000 # Memory (2Gb)
#SBATCH -t 0-1:00 # Maximum execution time (D-HH:MM)
#SBATCH -o cookie_%A_%a.out # Standard output
#SBATCH -e cookie_%A_%a.err # Standard error

/bin/bash "${SCRATCH}/cookies/cookie${SLURM_ARRAY_TASK_ID}".txt
```

We would then submit that one job file, and 100 jobs would be run to process our
cookie text files!

```bash
sbatch cookie-job.sbatch
```

That's the essense of a job array. It's actually exactly as it sounds - an array
of jobs.

## Why a tool like smanage?

Once you launch your jobs, you lose them to some extent because they are all individual.
jobs. There are technically command line ways to interact and control them, but
it's yet another hard-to-learn thing and (wouldn't it be nice) if there was a tool
to manage arrays for us?

This is the goal of smanage. Now that you understand, let's walk through usage.

# Usage

## Docker and Singularity

To make installation easier, we've provided a [Docker container](https://cloud.docker.com/u/srcc/repository/docker/srcc/smanage) that can be pulled via Singularity to run on 
a cluster resource.

```bash
$ singularity pull docker://srcc/smanage
WARNING: Authentication token file not found : Only pulls of public images will succeed
INFO:    Starting build...
Getting image source signatures
Copying blob sha256:cd784148e3483c2c86c50a48e535302ab0288bebd587accf40b714fffd0646b3
 2.10 MiB / 2.10 MiB [======================================================] 0s
Copying blob sha256:596816525d28fa4a320d55ac0936959d3aa1384c7e73c7a5dbc822fa70a7b9ed
 1.12 MiB / 1.12 MiB [======================================================] 0s
Copying blob sha256:36855b2d163c3615c90b416f8a316479bfe5fa4ac017a1d01da83d490c3d4739
 5.71 KiB / 5.71 KiB [======================================================] 0s
Copying blob sha256:56bf999a378723585d47346d0d44bd74c006d3e62085d8858f2a19f1901cfeac
 5.71 KiB / 5.71 KiB [======================================================] 0s
Copying config sha256:abf632e5ff9f35ae59c85a636c3429dbcc78df9b198f0daecd0720689c1dca0c
 1.33 KiB / 1.33 KiB [======================================================] 0s
Writing manifest to image destination
Storing signatures
INFO:    Creating SIF file...
INFO:    Build complete: smanage_latest.sif
```

Once you have it, try running the container to see its usage. We also need to bind
the /bin/scontrol executable and other libraries to the container so it can interact with our cluster.

```bash
$ singularity run --bind /usr/bin/scontrol --bind /etc/slurm --bind /etc/munge --bind /var/run/munge smanage_dev.sif
usage: smanage [FLAGS] <MODE> [MODE_ARGS]

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
```


## Local

For local usage, you can install the script by adding an alias to the program. 
Run the following line of code or copy it into the file '~/.bashrc' to make it permanent:

```bash
alias smanage='<pathto>/smanage.sh'
```

Whether you install it locally or use a container, smanage has two basic modes described below.


## Report Mode (default): smanage report
The reporting mode parses the output from sacct to create more consise output for large sets of job runs. 
The most useful example is to show the number of jobs in each state. The following is the output from a batch of 1000 jobs submitted using 'sacct --array' named "BATCH_JOBS":

```
$ smanage report --sacct --name=BATCH_JOBS
Finding jobs using: /usr/bin/sacct -XP --noheader --name=BATCH_JOBS
8 COMPLETED jobs
2 FAILED jobs
0 TIMEOUT jobs
8 RUNNING jobs
982 PENDING jobs
```

When using the report mode, any of the sacct commands can be added to generate a report on specific jobs. For example, to report the jobs ran on a specific date (note, on that date 1000 jobs named BATCH_JOBS ran to completion):

```
$ smanage report --sacct --name=BATCH_JOBS --starttime=2018-08-27
Finding jobs using: /usr/bin/sacct -XP --noheader --name=BATCH_JOBS
1008 COMPLETED jobs
2 FAILED jobs
0 TIMEOUT jobs
8 RUNNING jobs
982 PENDING jobs
```

Adding the '--verbose' flag adds more useful information about the jobs. When added to the example above and providing the sacct flag to only see COMPLETED jobs, the run time information is added to the output: 


```
$ smanage --verbose report --name=BATCH_JOBS --starttime=2018-08-27 --state=COMPLETED
Finding jobs using: /usr/bin/sacct -XP --noheader --name=BATCH_JOBS
1008 COMPLETED jobs
Avg Run Time: 02:14:15
Avg Wall Time: 07:33:40
```

When looking at FAILED jobs, providing a path to the directory where the .err files are for the run prints the errors for these jobs and a list of jobs to rerun (for easy copy and paste into your next 'sbatch --array' or 'smanage --submit' call):

```
$ smanage --verbose report --name=BATCH_JOBS --starttime=2018-08-27 --state=FAILED
Finding jobs using: /usr/bin/sacct -XP --noheader --name=BATCH_JOBS
2 FAILED jobs
Job 34 Failed: "ls: ~/myjobdir/: No such file or directory"
Job 52 Failed: "ls: ~/myjobdir/: No such file or directory"
Rerun these jobs: 34,52
```

The output for verbose commands can be extended to parse the .err or .out files to provided even more information using the 'SMANAGE_EXT_SOURCE' environment variable.

## Submit Mode: smanage submit

The smanage submit mode adds extra functionality to sbatch when submitting and tracking more jobs than the MaxArraySize allowed by slurm.

For simple jobs, use the exact same arguments as when using sbatch. A batch name is required and is provided to smanage using the argument '--batch-name=' or by specifying the sbatch argument '--job-name='. A CONFIG file is not required and is not be created for these types of job submittions.

```
$ smanage submit --sbatch --job-name="BATCH_JOB" <sbatch_script> <sbatch_script_args>
Submitting batch
Submitting jobs: /usr/bin/sbatch --job-name="BATCH_JOB" <sbatch_script> <sbatch_script_args>

Submitted batch job <job_id>
```

smanage extends the number of batch jobs one can submit beyond the MaxArraySize set by slurm. The script controls the number of jobs submitted at each call using a CONFIG file containing a reserve size (the maximum number of jobs allowed to be submitted) and maximum job id (the last job id to submit). The reserve and max_id can be initialized using the smanage '--max_id' and '--reserve' arguments.

The following example runs a batch of 10,000 jobs with a reserve of 1,000 jobs at-a-time:

```
$ smanage submit --reserve 1000 --max_id 9999 --sbatch --job-name="BATCH_JOB" <sbatch_script> <sbatch_script_args>
Creating CONFIG file BATCH_JOB_CONFIG
Submitting batch BATCH_JOB jobs 0-999 as array 0-999
Submitting jobs: /usr/bin/sbatch --array=0-999 --job-name="BATCH_JOB" <sbatch_script> <sbatch_script_args>

Submitted batch job <job_id_0>
Appending <job_id_0> to BATCH_JOB_CONFIG
```

For this call, smanage creates a CONFIG file automatically. It can be used for subsequent calls to smanage submit.
```
BATCH_NAME=BATCH_JOB
BATCH_DATE=<job_date>
JOB_IDS=<job_id_0>

RESERVE=1000
MAX_ID=9999

SBATCH_ARGS="--job-name="BATCH_JOB" <sbatch_script> <sbatch_script_args>"

NEXT_RUN_ID=1000
LAST_RUN_ID=999
```

smanage uses sacct output to count the number of PENDING and RUNNING jobs for this batch. It then submits an array of jobs to fill the reserve quota. If 950 of the initial 1000 jobs are PENDING or RUNNING, the next smanage submit call submits 50 jobs:

```
$ smanage submit --config BATCH_JOB_CONFIG
Finding jobs using: /usr/bin/sacct -XP --noheader --jobs=<job_id> --name=BATCH_JOB -S <job_date>
Found jobs: <job_id>

Submitting batch BATCH_JOB jobs 1000-1049 as array 0-49
Calling: /usr/bin/sbatch --array=0-49 --job-name="BATCH_JOB" <sbatch_script> <sbatch_script_args>

Submitted batch job <job_id_1>
Appending <job_id_1> to BATCH_JOB_CONFIG
```

smanage can be called at timed intervals making use of [crontab](https://crontab.guru). smanage continues to submit jobs to the slurm scheduler until it reaches the max_id. The example cron job below calls 'smanage submit' every half hour and 'smanage report' every four hours at ten minutes past the hour. Output from the calls are emailed to the user automatically.

```
CONFIG=<path_to>/BATCH_JOB_CONFIG
*/30 * * * * ~/smanage/smanage.sh submit --config $CONFIG
10 */4 * * * ~/smanage/smanage.sh report --config $CONFIG
```

## Accessing variable in the CONFIG file in an sbatch script

Some use cases require accessing variables in the CONFIG file in an sbatch script. smanage submit automatically appends the path to the CONFIG file as the last item to the sbatch arguments. Therefore the variables in the CONFIG file can be accessed in the sbatch script by reading them directly or using the bash 'source' command to load the variables. 

This example reads the NEXT_RUN_ID variable from the CONFIG file and uses it to list the items in a directory.

```
#!/bin/bash
#
#SBATCH -p shared

RUN_ID=$SLURM_ARRAY_TASK_ID
if [[ $# -gt 0 ]]; then
    LAST_ARG=${*: -1}
    if [[ -n $LAST_ARG && -e $(readlink -f $LAST_ARG) ]]; then
        CONFIG=$(readlink -f $LAST_ARG)
        source $CONFIG
        # the variable NEXT_RUN_ID now contains the value in the CONFIG file
        RUN_ID=$(($NEXT_RUN_ID + $SLURM_ARRAY_TASK_ID))
    fi
fi

ls batches/batch_dir_${RUN_ID}
```

# Development

To build the Docker container locally:

```bash
$ docker build -t srcc/smanage .
```
