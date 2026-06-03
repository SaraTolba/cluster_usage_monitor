# monitor_pbs_running_utilization.sh

Finds running PBS / OpenPBS jobs that waste resources — jobs leaving most of their CPU cores idle, or running near their memory limit. Read-only: it only reads `qstat`, never changes jobs.

## How it works

Runs `qstat` to list running (`R`) jobs, reads each with `qstat -fx`, and computes:

```
cpu_util% = resources_used.cpupercent / Resource_List.ncpus      # 393 / 8 ≈ 49%
mem_util% = resources_used.mem / Resource_List.mem * 100
```

A job is flagged `PROBLEM` if CPU is below `--low-cpu` (default 20%) or memory is above `--high-mem` (default 90%).

## Usage

```
chmod +x monitor_pbs_running_utilization.sh
./monitor_pbs_running_utilization.sh [OPTIONS]
```

By default it prints **only the flagged jobs**, across all users. No rows = all healthy; `No running jobs found.` = nothing running.

### Key options

- `--show-ok` — also show healthy jobs
- `--low-cpu N` / `--high-mem N` — set thresholds (e.g. `--low-cpu 50`)
- `--low-mem N` — also flag jobs using less than N% of requested memory
- `--min-walltime MIN` — skip jobs younger than this (default 10)
- `--user NAME` — limit to one user
- `--job JOBID` — check a single job
- `--csv FILE` — write a full report (all jobs) to CSV
- `-v` — per-job detail; `-h` — full help

### Examples

```
./monitor_pbs_running_utilization.sh                       # current offenders
./monitor_pbs_running_utilization.sh --show-ok             # everything
./monitor_pbs_running_utilization.sh --low-cpu 50          # flag half-idle jobs
./monitor_pbs_running_utilization.sh --user yiting.song -v
./monitor_pbs_running_utilization.sh --csv running_jobs.csv
```

## Requirements

PBS/OpenPBS with `qstat` on `PATH`, plus `awk`, `sed`, `date`. Assumes the standard `qstat -fx` format (4-space attribute indent, tab-wrapped continuation lines).

## Caveats

Default `qstat` may truncate very long job IDs. For multi-node jobs, `mem%` can read high if `Resource_List.mem` is per-chunk. Treat flags as hints, not verdicts — tune the thresholds to your cluster.
