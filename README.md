# PBS Cluster Usage Monitor

Two read-only command-line checks for PBS Pro / OpenPBS clusters:

| Script | Purpose |
|---|---|
| `monitor_pbs_stuck_jobs.sh` | Finds queued and held jobs that likely require user or administrator attention. |
| `monitor_pbs_running_utilization.sh` | Finds running jobs with low CPU use or unusually high/low memory use relative to their requests. |

Neither script holds, releases, deletes, or otherwise changes jobs. They query PBS with `qstat` (and, for the stuck-job check, `qselect`) and print a report.

## Quick start

The scripts are executable in this repository. Run them on a host where the PBS client commands and, for the stuck-job check, the site node-inventory command are available.

```bash
./monitor_pbs_stuck_jobs.sh
./monitor_pbs_running_utilization.sh
```

If the executable bits are lost after copying the files:

```bash
chmod +x monitor_pbs_stuck_jobs.sh monitor_pbs_running_utilization.sh
```

## Stuck queued and held jobs

`monitor_pbs_stuck_jobs.sh` checks queued (`Q`) and held (`H`) jobs by default.

For queued jobs, it compares each `Resource_List.select` request with the node inventory from `freenodes -gco` and flags:

- explicit `host=` or `vnode=` names that do not exist;
- a per-chunk `ncpus`, `mem`, `ngpus`, or `gpu_type` request that no single node can provide;
- scheduler comments suggesting a resource problem, only when `--check-comments` is requested.

The capacity check uses each node's total capacity—not current free capacity—so it answers whether the request can ever fit. Requests using unexpanded node ranges, such as `node[001-003]`, are skipped rather than guessed.

Held jobs are classified rather than automatically treated as stuck:

- user, operator, and password holds are actionable;
- system holds without a dependency are flagged for investigation;
- dependency holds whose parent is missing or completed in a way that can never satisfy `afterok`/`afternotok` are flagged;
- dependency holds waiting on a parent that is still present are reported as normal and are not counted as problems.

### Usage

```bash
./monitor_pbs_stuck_jobs.sh                         # queued and held jobs
./monitor_pbs_stuck_jobs.sh -Q -d 7 -v              # queued jobs at least 7 days old
./monitor_pbs_stuck_jobs.sh -H --include-normal-holds
./monitor_pbs_stuck_jobs.sh --exit-nonzero > report.txt
```

| Option | Description |
|---|---|
| `-Q`, `--queued-only` | Inspect queued jobs only. |
| `-H`, `--held-only` | Inspect held jobs only. |
| `-d DAYS`, `--days DAYS` | Inspect only jobs at least `DAYS` old, based on `qtime`. |
| `-v`, `--verbose` | Show detailed PBS attributes for flagged jobs. |
| `--freenodes-cmd CMD` | Use another node-inventory command with the same column layout as `freenodes -gco`. |
| `--check-comments` | Include scheduler resource comments; this can be noisy for jobs merely waiting on busy resources. |
| `--include-normal-holds` | Print normal dependency holds for review. |
| `--skip-dep-parent-check` | Do not query dependency parents; treats dependency holds as normal. |
| `--show-all-problem-jobs` | Do not limit the summary's problem-job list to 25 entries. |
| `--exit-nonzero` | Exit with status 2 when actionable jobs are found. |
| `-h`, `--help` | Show full help. |

Example finding:

```text
648053.bright04 [QUEUED] - unsatisfiable resources -> CONTACT USER: chunk 1 (ngpus=8 > max per-node 2)
```

## Running-job utilization

`monitor_pbs_running_utilization.sh` lists running (`R`) jobs, reads each with `qstat -fx`, and evaluates CPU and memory use against the requested allocation.

```text
CPU utilization (%) = resources_used.cpupercent / Resource_List.ncpus
Memory utilization (%) = resources_used.mem / Resource_List.mem * 100
```

PBS reports `cpupercent` as a percentage of one CPU core; for example, `cpupercent=393` on an 8-core allocation is about 49.1% of the allocation. If `Resource_List.mem` is unavailable, the script falls back to the memory value in `exec_vnode`.

By default, only jobs flagged as `PROBLEM` are printed:

- CPU use below 20% of requested cores;
- memory use above 90% of requested memory.

The default 10-minute minimum walltime avoids alerting on newly started jobs. A missing table row means no job met the selected reporting criteria; `No running jobs found.` means PBS reported no running jobs.

### Usage

```bash
./monitor_pbs_running_utilization.sh
./monitor_pbs_running_utilization.sh --show-ok
./monitor_pbs_running_utilization.sh --low-cpu 50 --high-mem 85
./monitor_pbs_running_utilization.sh --low-mem 10 --user yiting.song -v
./monitor_pbs_running_utilization.sh --job 687593.bright04
./monitor_pbs_running_utilization.sh --csv running_jobs.csv
```

| Option | Description |
|---|---|
| `--show-ok` | Include jobs that do not cross a threshold. |
| `--problems-only` | Print only threshold violations (the default behavior). |
| `--low-cpu PERCENT` | Flag CPU utilization below this value; default `20`. |
| `--high-mem PERCENT` | Flag memory utilization above this value; default `90`. |
| `--low-mem PERCENT` | Also flag memory utilization below this value. |
| `--min-walltime MINUTES` | Ignore jobs younger than this runtime; default `10`. |
| `--user USERNAME` | Limit the scan to a job owner. |
| `--job JOBID` | Inspect one running job. |
| `--csv FILE` | Write a CSV report for every processed running job, including jobs not printed to the terminal. |
| `--no-header` | Omit the terminal table header. |
| `-v`, `--verbose` | Print raw utilization details for displayed jobs. |
| `-h`, `--help` | Show full help. |

## Requirements and compatibility

Both scripts need Bash, `qstat`, `awk`, `sed`, and `date`. The stuck-job checker also needs `qselect`, `freenodes -gco` (or an equivalent supplied with `--freenodes-cmd`), `grep`, `sort`, `cut`, `tr`, and `mktemp`.

The scripts expect the standard PBS `qstat -fx` attribute format, including space-indented attributes and tab-indented wrapped continuations. The stuck-job checker supports gawk and mawk. Its `--days` filter uses GNU `date -d`; on macOS, run it in an environment that provides GNU date.

For multi-node jobs, treat the running-job memory percentage as a diagnostic signal rather than a final accounting value: `Resource_List.mem` can represent a per-chunk request while the usage value may be aggregated differently by the site configuration. Tune thresholds to the cluster and workload.

## Exit status

`monitor_pbs_stuck_jobs.sh` returns:

- `0` for a completed check, including when problems are found unless `--exit-nonzero` is set;
- `1` for setup, command, inventory, or argument errors;
- `2` when `--exit-nonzero` is set and one or more actionable jobs are found.

The running-utilization script returns a nonzero status for invalid arguments or missing required commands; threshold violations are reported in its output rather than through a dedicated exit status.
