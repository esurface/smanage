# smanage
Slurm Manage, for submitting and reporting on job arrays run on slurm

The script manages jobs running on a compute cluster that uses the [SLURM scheduler](https://slurm.schedmd.com/). 
It was developed in bash to take advantage of the automatic output from the [slurm programs available on the command line](https://slurm.schedmd.com/pdfs/summary.pdf), namely sacct and sbatch. As a key feature, smanage enables the user to submit and track large batches of jobs beyond the MaxArraySize limit set by slurm. 

The easiest way to install the script by adding an alias to the program. Run the following line of code or copy it into the file '~/.bashrc' to make it perminant:
```
alias smanage='<pathto>/smanage.sh'
```

The script has two basic modes described below.



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

## Submit Mode: smanage --submit

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

