# [1] monitor_pbs_stuck_jobs.sh

Read-only checker for PBS Pro / OpenPBS that flags **queued** and **held** jobs needing
attention — above all, queued jobs that can **never** run because they ask for a node name
or a per-node resource amount the cluster cannot provide.

It only reads cluster state (`qstat`, `qselect`, `freenodes -gco`). It never holds,
releases, deletes, or modifies jobs.

## What it flags

- **Nonexistent nodes** — a `host=`/`vnode=` in `Resource_List.select` that no node matches.
- **Unsatisfiable resources** — a `select` chunk whose `ncpus`/`mem`/`ngpus`/`gpu_type` no
  *single* node can satisfy (e.g. `ncpus=200` when the largest node has 192 cores). These are
  marked `CONTACT USER`.
- **Held jobs** — listed for review.

Feasibility is checked per chunk against one node's **total** capacity (not free, so "can it
ever run"), and is conservative: unparseable selects and ranges like `host=node[001-003]`
are skipped, never guessed.

## Requirements

`bash`, `qstat`, `qselect`, a node-inventory command (`freenodes -gco` by default), and the
usual `awk`/`grep`/`sort`/`cut`/`mktemp`/`date`. Works with gawk or mawk. The `--days` filter
needs GNU `date`.

## Install

```bash
chmod +x monitor_pbs_stuck_jobs.sh
```

## Usage

```bash
monitor_pbs_stuck_jobs.sh            # check held + queued (default)
monitor_pbs_stuck_jobs.sh -Q -d 7 -v # queued only, older than 7 days, verbose
monitor_pbs_stuck_jobs.sh --exit-nonzero --show-all-problem-jobs > report.txt
```

| Option | Description |
|---|---|
| `-Q` / `-H` | Queued-only / held-only |
| `-v` | Verbose per-job diagnostics |
| `-d DAYS` | Only jobs older than `DAYS` (by `qtime`) |
| `--freenodes-cmd CMD` | Override node-inventory command (same column layout required) |
| `--exit-nonzero` | Exit `2` if anything is flagged (for cron/alerting) |
| `--check-comments` | Also flag scheduler resource comments (off by default — noisy) |
| `--show-all-problem-jobs` | Don't truncate the list at 25 |
| `-h` | Help |

## Example

```
648053.bright04 [QUEUED] - unsatisfiable resources -> CONTACT USER: chunk 1 (ngpus=8 > max per-node 2)
648045.bright04 [QUEUED] - requested node(s) not found in freenodes: gpu0059
```

`chunk N` is the Nth `+`-separated part of the job's `select`; run with `-v` to see the full
request.

## Exit codes

`0` ok · `1` setup error (missing command, no nodes parsed, bad args) · `2` problems found
(with `--exit-nonzero`).


# [2] monitor_pbs_running_utilization.sh

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
