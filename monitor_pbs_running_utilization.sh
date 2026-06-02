#!/usr/bin/env bash
# monitor_pbs_running_utilization.sh
# Monitor CPU and memory utilization of running PBS/OpenPBS jobs using qstat -fx.
#
# Main checks:
#   - resources_used.cpupercent compared with requested Resource_List.ncpus
#   - resources_used.mem compared with requested Resource_List.mem or exec_vnode mem
#
# CPU logic:
#   PBS cpupercent is usually percent of one CPU core.
#   A job using 32 cores fully should report about 3200 cpupercent.
#   CPU utilization percent of allocation = cpupercent / (ncpus * 100) * 100.
#
# Examples:
#   ./monitor_pbs_running_utilization.sh
#   ./monitor_pbs_running_utilization.sh -v
#   ./monitor_pbs_running_utilization.sh --low-cpu 20 --high-mem 90
#   ./monitor_pbs_running_utilization.sh --user hadassah.griffin
#   ./monitor_pbs_running_utilization.sh --csv running_jobs.csv
#   ./monitor_pbs_running_utilization.sh --job 681910.bright04

set -o pipefail

LOW_CPU_THRESHOLD=20
HIGH_MEM_THRESHOLD=90
LOW_MEM_THRESHOLD=""
MIN_WALLTIME_MINUTES=10
VERBOSE=false
CSV_FILE=""
USER_FILTER=""
JOB_ID=""
SHOW_OK=false
ONLY_PROBLEMS=false
INCLUDE_HEADER=true

show_help() {
    cat <<'HELP'
Usage: monitor_pbs_running_utilization.sh [OPTIONS]

Checks running PBS jobs using qstat -fx and reports low CPU or high memory usage.

OPTIONS:
    -h, --help                  Show this help message
    -v, --verbose               Show detailed job information
    --show-ok                   Also print jobs that do not cross thresholds
    --problems-only             Print only jobs crossing thresholds; default summary already focuses on problems
    --low-cpu PERCENT           Flag jobs below this CPU utilization of requested ncpus [default: 20]
    --high-mem PERCENT          Flag jobs above this memory utilization of requested mem [default: 90]
    --low-mem PERCENT           Optional: flag jobs below this memory utilization of requested mem
    --min-walltime MINUTES      Ignore jobs younger than this runtime [default: 10]
    --user USERNAME             Check only jobs owned by this username
    --job JOBID                 Check a single job ID
    --csv FILE                  Write CSV report to FILE
    --no-header                 Do not print the table header

EXAMPLES:
    ./monitor_pbs_running_utilization.sh
    ./monitor_pbs_running_utilization.sh -v
    ./monitor_pbs_running_utilization.sh --low-cpu 10 --high-mem 95
    ./monitor_pbs_running_utilization.sh --user hadassah.griffin
    ./monitor_pbs_running_utilization.sh --job 681910.bright04
    ./monitor_pbs_running_utilization.sh --csv running_jobs.csv

NOTES:
    CPU percent interpretation:
      cpu_util_percent = resources_used.cpupercent / (requested_ncpus * 100) * 100

    Example:
      cpupercent=3023 and ncpus=32 means about 94.5% of the requested CPU allocation.
HELP
}

err() {
    echo "ERROR: $*" >&2
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --show-ok)
            SHOW_OK=true
            shift
            ;;
        --problems-only)
            ONLY_PROBLEMS=true
            shift
            ;;
        --low-cpu)
            LOW_CPU_THRESHOLD="$2"
            is_number "$LOW_CPU_THRESHOLD" || { err "--low-cpu must be numeric"; exit 1; }
            shift 2
            ;;
        --high-mem)
            HIGH_MEM_THRESHOLD="$2"
            is_number "$HIGH_MEM_THRESHOLD" || { err "--high-mem must be numeric"; exit 1; }
            shift 2
            ;;
        --low-mem)
            LOW_MEM_THRESHOLD="$2"
            is_number "$LOW_MEM_THRESHOLD" || { err "--low-mem must be numeric"; exit 1; }
            shift 2
            ;;
        --min-walltime)
            MIN_WALLTIME_MINUTES="$2"
            [[ "$MIN_WALLTIME_MINUTES" =~ ^[0-9]+$ ]] || { err "--min-walltime must be an integer"; exit 1; }
            shift 2
            ;;
        --user)
            USER_FILTER="$2"
            shift 2
            ;;
        --job)
            JOB_ID="$2"
            shift 2
            ;;
        --csv)
            CSV_FILE="$2"
            shift 2
            ;;
        --no-header)
            INCLUDE_HEADER=false
            shift
            ;;
        *)
            err "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
 done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }
}

require_cmd qstat
require_cmd awk
require_cmd sed
require_cmd date

# Convert PBS memory value to KB.
# Supports kb, mb, gb, tb, bare numbers treated as KB.
mem_to_kb() {
    local raw="$1"
    raw=$(echo "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$raw" || "$raw" == "--" ]]; then
        echo "0"
        return
    fi
    awk -v v="$raw" '
        BEGIN {
            n = v
            unit = "kb"
            if (match(v, /^[0-9.]+/)) {
                n = substr(v, RSTART, RLENGTH) + 0
                unit = substr(v, RSTART + RLENGTH)
            }
            if (unit == "" || unit == "kb" || unit == "k") mult = 1
            else if (unit == "mb" || unit == "m") mult = 1024
            else if (unit == "gb" || unit == "g") mult = 1024 * 1024
            else if (unit == "tb" || unit == "t") mult = 1024 * 1024 * 1024
            else mult = 1
            printf "%.0f\n", n * mult
        }'
}

# Convert HH:MM:SS, MM:SS, or seconds to minutes.
time_to_minutes() {
    local t="$1"
    awk -v t="$t" '
        BEGIN {
            n = split(t, a, ":")
            if (n == 3) sec = a[1] * 3600 + a[2] * 60 + a[3]
            else if (n == 2) sec = a[1] * 60 + a[2]
            else sec = t + 0
            printf "%.0f\n", sec / 60
        }'
}

# Join qstat continuation lines. PBS often wraps long attributes onto a tab-indented next line.
normalize_qstat() {
    awk '
        /^[[:space:]]/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (current != "") current = current line
            else current = line
            next
        }
        {
            if (current != "") print current
            current = $0
        }
        END { if (current != "") print current }
    '
}

get_attr() {
    local data="$1"
    local key="$2"
    echo "$data" | awk -v key="$key" '
        index($0, key " = ") == 5 {
            sub("^    " key " = ", "")
            print
            exit
        }
    '
}

get_job_id_from_data() {
    local data="$1"
    echo "$data" | awk '/^Job Id:/ {print $3; exit}'
}

extract_exec_vnode_mem_kb() {
    local exec_vnode="$1"
    local mem
    mem=$(echo "$exec_vnode" | grep -oE 'mem=[0-9]+[a-zA-Z]*' | head -n 1 | sed 's/^mem=//')
    if [[ -n "$mem" ]]; then
        mem_to_kb "$mem"
    else
        echo "0"
    fi
}

csv_escape() {
    local s="$1"
    s=${s//\"/\"\"}
    printf '"%s"' "$s"
}

print_header() {
    printf '%-18s %-22s %-18s %-10s %-8s %-10s %-10s %-9s %-9s %-s\n' \
        "JOB_ID" "OWNER" "NAME" "QUEUE" "NCPUS" "CPU%" "MEM%" "WALL" "STATUS" "REASONS"
}

print_row() {
    local job_id="$1" owner="$2" name="$3" queue="$4" ncpus="$5" cpu_util="$6" mem_util="$7" walltime="$8" status="$9" reasons="${10}"
    printf '%-18s %-22s %-18s %-10s %-8s %-10s %-10s %-9s %-9s %-s\n' \
        "$job_id" "$owner" "$name" "$queue" "$ncpus" "$cpu_util" "$mem_util" "$walltime" "$status" "$reasons"
}

write_csv_header() {
    [[ -n "$CSV_FILE" ]] || return
    echo 'job_id,owner,job_name,queue,state,ncpus,cpupercent,cpu_util_percent,mem_used_kb,mem_request_kb,mem_util_percent,walltime,status,reasons' > "$CSV_FILE"
}

write_csv_row() {
    [[ -n "$CSV_FILE" ]] || return
    local job_id="$1" owner="$2" name="$3" queue="$4" state="$5" ncpus="$6" cpupercent="$7" cpu_util="$8" mem_used_kb="$9" mem_request_kb="${10}" mem_util="${11}" walltime="${12}" status="${13}" reasons="${14}"
    {
        csv_escape "$job_id"; printf ','
        csv_escape "$owner"; printf ','
        csv_escape "$name"; printf ','
        csv_escape "$queue"; printf ','
        csv_escape "$state"; printf ','
        csv_escape "$ncpus"; printf ','
        csv_escape "$cpupercent"; printf ','
        csv_escape "$cpu_util"; printf ','
        csv_escape "$mem_used_kb"; printf ','
        csv_escape "$mem_request_kb"; printf ','
        csv_escape "$mem_util"; printf ','
        csv_escape "$walltime"; printf ','
        csv_escape "$status"; printf ','
        csv_escape "$reasons"; printf '\n'
    } >> "$CSV_FILE"
}

get_running_jobs() {
    if [[ -n "$JOB_ID" ]]; then
        echo "$JOB_ID"
        return
    fi

    if [[ -n "$USER_FILTER" ]]; then
        qselect -s R -u "$USER_FILTER" 2>/dev/null || true
    else
        qselect -s R 2>/dev/null || true
    fi
}

process_job() {
    local job_id="$1"
    local raw data state owner name queue cpupercent cput mem_used_raw mem_used_kb ncpus req_mem_raw req_mem_kb exec_mem_kb walltime wall_min
    local cpu_util mem_util status reasons should_print

    raw=$(qstat -fx "$job_id" 2>/dev/null) || return
    data=$(printf '%s\n' "$raw" | normalize_qstat)

    job_id=$(get_job_id_from_data "$data")
    [[ -n "$job_id" ]] || return

    state=$(get_attr "$data" "job_state")
    [[ "$state" == "R" ]] || return

    owner=$(get_attr "$data" "Job_Owner")
    owner=${owner%@*}
    name=$(get_attr "$data" "Job_Name")
    queue=$(get_attr "$data" "queue")
    cpupercent=$(get_attr "$data" "resources_used.cpupercent")
    cput=$(get_attr "$data" "resources_used.cput")
    mem_used_raw=$(get_attr "$data" "resources_used.mem")
    ncpus=$(get_attr "$data" "Resource_List.ncpus")
    [[ -z "$ncpus" ]] && ncpus=$(get_attr "$data" "resources_used.ncpus")
    req_mem_raw=$(get_attr "$data" "Resource_List.mem")
    walltime=$(get_attr "$data" "resources_used.walltime")

    [[ -z "$cpupercent" ]] && cpupercent=0
    [[ -z "$ncpus" || "$ncpus" == "0" ]] && ncpus=0
    [[ -z "$walltime" ]] && walltime="00:00:00"
    wall_min=$(time_to_minutes "$walltime")

    # Avoid false alarms for very new jobs.
    if (( wall_min < MIN_WALLTIME_MINUTES )); then
        return
    fi

    mem_used_kb=$(mem_to_kb "$mem_used_raw")
    req_mem_kb=$(mem_to_kb "$req_mem_raw")

    # If Resource_List.mem is absent, fall back to exec_vnode mem.
    if [[ "$req_mem_kb" == "0" ]]; then
        exec_mem_kb=$(extract_exec_vnode_mem_kb "$(get_attr "$data" "exec_vnode")")
        req_mem_kb="$exec_mem_kb"
    fi

    if [[ "$ncpus" -gt 0 ]]; then
        cpu_util=$(awk -v cpu="$cpupercent" -v n="$ncpus" 'BEGIN { printf "%.1f", cpu / n }')
    else
        cpu_util="NA"
    fi

    if [[ "$req_mem_kb" -gt 0 ]]; then
        mem_util=$(awk -v used="$mem_used_kb" -v req="$req_mem_kb" 'BEGIN { printf "%.1f", (used / req) * 100 }')
    else
        mem_util="NA"
    fi

    status="OK"
    reasons=""

    if [[ "$cpu_util" != "NA" ]]; then
        awk -v v="$cpu_util" -v t="$LOW_CPU_THRESHOLD" 'BEGIN { exit !(v < t) }'
        if [[ $? -eq 0 ]]; then
            status="PROBLEM"
            reasons+="LOW_CPU(${cpu_util}%<${LOW_CPU_THRESHOLD}%) "
        fi
    fi

    if [[ "$mem_util" != "NA" ]]; then
        awk -v v="$mem_util" -v t="$HIGH_MEM_THRESHOLD" 'BEGIN { exit !(v > t) }'
        if [[ $? -eq 0 ]]; then
            status="PROBLEM"
            reasons+="HIGH_MEM(${mem_util}%>${HIGH_MEM_THRESHOLD}%) "
        fi

        if [[ -n "$LOW_MEM_THRESHOLD" ]]; then
            awk -v v="$mem_util" -v t="$LOW_MEM_THRESHOLD" 'BEGIN { exit !(v < t) }'
            if [[ $? -eq 0 ]]; then
                status="PROBLEM"
                reasons+="LOW_MEM(${mem_util}%<${LOW_MEM_THRESHOLD}%) "
            fi
        fi
    fi

    reasons=$(echo "$reasons" | sed 's/[[:space:]]*$//')

    write_csv_row "$job_id" "$owner" "$name" "$queue" "$state" "$ncpus" "$cpupercent" "$cpu_util" "$mem_used_kb" "$req_mem_kb" "$mem_util" "$walltime" "$status" "$reasons"

    should_print=false
    if [[ "$status" == "PROBLEM" ]]; then
        should_print=true
    elif [[ "$SHOW_OK" == true && "$ONLY_PROBLEMS" == false ]]; then
        should_print=true
    fi

    if [[ "$should_print" == true ]]; then
        print_row "$job_id" "$owner" "$name" "$queue" "$ncpus" "$cpu_util" "$mem_util" "$walltime" "$status" "$reasons"

        if [[ "$VERBOSE" == true ]]; then
            echo "  cpupercent: $cpupercent"
            echo "  used mem:   $mem_used_raw (${mem_used_kb}kb)"
            echo "  req mem:    ${req_mem_raw:-unknown} (${req_mem_kb}kb)"
            echo "  cput:       ${cput:-unknown}"
            echo "  walltime:   $walltime"
            echo "  queue:      $queue"
            echo "  owner:      $owner"
            echo ""
        fi
    fi
}

jobs=$(get_running_jobs)

if [[ -z "$jobs" ]]; then
    echo "No running jobs found."
    exit 0
fi

write_csv_header

if [[ "$INCLUDE_HEADER" == true ]]; then
    print_header
fi

count_total=0
for job in $jobs; do
    count_total=$((count_total + 1))
    process_job "$job"
done

if [[ -n "$CSV_FILE" ]]; then
    echo "CSV written to: $CSV_FILE"
fi

if [[ "$VERBOSE" == true ]]; then
    echo "Checked running jobs: $count_total"
fi
