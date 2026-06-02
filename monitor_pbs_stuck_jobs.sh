#!/usr/bin/env bash
# monitor_pbs_stuck_jobs.sh
# Weekly PBS stuck-job checker.
# Flags queued/held jobs that may never run, especially jobs requesting host/vnode
# names that do not exist in the current freenodes -gco node list.

set -u
set -o pipefail

CHECK_HELD=true
CHECK_QUEUED=true
VERBOSE=false
DAYS=""
FREENODES_CMD="freenodes -gco"
QSTAT_CMD="qstat"
QSELECT_CMD="qselect"
EXIT_NONZERO=false
SHOW_ALL_PROBLEM_JOBS=false

usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Checks queued and/or held PBS jobs for conditions that likely require admin/user action.
The most important check compares requested host= or vnode= values in qstat -fx
against node names reported by: freenodes -gco

Options:
  -h, --help                 Show this help message
  -Q, --queued-only          Check only queued jobs
  -H, --held-only            Check only held jobs
  -v, --verbose              Print detailed diagnostics for each flagged job
  -d, --days DAYS            Only inspect queued/held jobs older than DAYS days
  --freenodes-cmd CMD        Override node-list command. Default: "freenodes -gco"
  --exit-nonzero             Exit 2 if any problematic job is found
  --show-all-problem-jobs    Print all flagged job IDs in summary

Examples:
  $0
  $0 -Q -d 7 -v
  $0 --freenodes-cmd "freenodes -gco"
  $0 --exit-nonzero > pbs_stuck_jobs_
USAGE
}

log_debug() {
    if [ "$VERBOSE" = true ]; then
        printf '%s\n' "$*" >&2
    fi
}

need_cmd() {
    local cmd_name="$1"
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "$cmd_name" >&2
        exit 1
    fi
}

trim() {
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# qstat -fx can wrap long attributes onto continuation lines that begin with tabs/spaces.
# This function joins continuation lines so Resource_List.select and comment are easier to parse.
normalize_qstat_fx() {
    awk '
        /^[[:space:]]/ {
            sub(/^[[:space:]]+/, "")
            printf " %s", $0
            next
        }
        NR > 1 { printf "\n" }
        { printf "%s", $0 }
        END { printf "\n" }
    '
}

get_attr() {
    local attr="$1"
    awk -v attr="$attr" '
        index($0, attr " = ") == 1 {
            sub(attr " = ", "")
            print
            exit
        }
    '
}

# Parse node names from freenodes -gco output.
# Assumption: the node/vnode name is the first whitespace-separated field on data lines.
# Header/separator lines are ignored.
load_cluster_nodes() {
    local output
    if ! output=$(eval "$FREENODES_CMD" 2>/dev/null); then
        printf 'ERROR: failed to run node-list command: %s\n' "$FREENODES_CMD" >&2
        exit 1
    fi

    printf '%s\n' "$output" |
        awk '
            NF == 0 { next }
            /^[[:space:]]*[-=]+[[:space:]]*$/ { next }
            NR == 1 && tolower($0) ~ /(node|host|vnode)/ { next }
            {
                node=$1
                gsub(/[,;:]+$/, "", node)
                if (node != "" && node !~ /^[#]/ && node !~ /^(node|host|vnode)$/i) print node
            }
        ' |
        sort -u
}

node_exists() {
    local node="$1"
    grep -Fxq "$node" "$NODE_FILE"
}

# Extract explicitly requested host/vnode names from Resource_List.select and similar fields.
# Examples handled:
#   1:ncpus=4:mem=10gb:host=node001
#   2:ncpus=8:vnode=node002+1:ncpus=8:host=node003
#   host=node[001-003] is reported as unexpanded, because this script avoids guessing ranges.
extract_requested_nodes() {
    awk '
        BEGIN { RS="[+[:space:]]+" }
        {
            while (match($0, /(host|vnode)=([^:+,[:space:]]+)/, m)) {
                print m[2]
                $0 = substr($0, RSTART + RLENGTH)
            }
        }
    ' | sort -u
}

get_job_age_days_from_normalized_info() {
    local qtime current job_time
    qtime=$(printf '%s\n' "$1" | get_attr "qtime")
    if [ -z "$qtime" ]; then
        printf 'unknown'
        return
    fi

    current=$(date +%s)
    if ! job_time=$(date -d "$qtime" +%s 2>/dev/null); then
        printf 'unknown'
        return
    fi
    printf '%s' $(( (current - job_time) / 86400 ))
}

select_jobs() {
    local state="$1"
    if [ -n "$DAYS" ]; then
        "$QSELECT_CMD" -s "$state" -tq.lt.$(date --date="$DAYS days ago" "+%Y%m%d%H%M") 2>/dev/null || true
    else
        "$QSELECT_CMD" -s "$state" 2>/dev/null || true
    fi
}

print_job_detail() {
    local state="$1"
    local job_id="$2"
    local info="$3"
    local reason="$4"
    local age
    age=$(get_job_age_days_from_normalized_info "$info")

    printf '\n=== %s JOB FLAGGED ===\n' "$state"
    printf 'Job: %s\n' "$job_id"
    printf 'Reason: %s\n' "$reason"
    printf 'Age: %s days\n' "$age"
    printf '%s\n' "$info" | grep -E '^(Job_Name|Job_Owner|job_state|queue|qtime|Hold_Types|comment|Resource_List\.(select|place|nodect|ncpus|mem|walltime)|Resource_List.preempt_targets) = ' | sed 's/^/  /'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -Q|--queued-only)
                CHECK_HELD=false
                ;;
            -H|--held-only)
                CHECK_QUEUED=false
                ;;
            -v|--verbose)
                VERBOSE=true
                ;;
            -s|--summary)
                VERBOSE=false
                ;;
            -d|--days)
                shift
                if [ "${1:-}" = "" ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
                    printf 'ERROR: --days requires a positive integer\n' >&2
                    exit 1
                fi
                DAYS="$1"
                ;;
            --freenodes-cmd)
                shift
                if [ "${1:-}" = "" ]; then
                    printf 'ERROR: --freenodes-cmd requires a command string\n' >&2
                    exit 1
                fi
                FREENODES_CMD="$1"
                ;;
            --exit-nonzero)
                EXIT_NONZERO=true
                ;;
            --show-all-problem-jobs)
                SHOW_ALL_PROBLEM_JOBS=true
                ;;
            *)
                printf 'ERROR: unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    need_cmd "$QSTAT_CMD"
    need_cmd "$QSELECT_CMD"
    need_cmd awk
    need_cmd grep
    need_cmd sort
    need_cmd mktemp

    NODE_FILE=$(mktemp)
    PROBLEM_FILE=$(mktemp)
    HELD_FILE=$(mktemp)
    QUEUED_FILE=$(mktemp)
    trap 'rm -f "$NODE_FILE" "$PROBLEM_FILE" "$HELD_FILE" "$QUEUED_FILE"' EXIT

    load_cluster_nodes > "$NODE_FILE"
    node_count=$(grep -c . "$NODE_FILE" || true)
    if [ "$node_count" -eq 0 ]; then
        printf 'ERROR: no nodes parsed from: %s\n' "$FREENODES_CMD" >&2
        exit 1
    fi

    printf 'PBS stuck-job check started: %s\n' "$(date)"
    printf 'Node source: %s (%s nodes parsed)\n' "$FREENODES_CMD" "$node_count"
    if [ -n "$DAYS" ]; then
        printf 'Age filter: only jobs older than %s days\n' "$DAYS"
    fi

    held_total=0
    queued_total=0
    missing_node_count=0
    insufficient_count=0
    held_count=0

    if [ "$CHECK_HELD" = true ]; then
        select_jobs H > "$HELD_FILE"
        held_total=$(grep -c . "$HELD_FILE" || true)
        held_count="$held_total"

        while IFS= read -r job_id; do
            [ -z "$job_id" ] && continue
            info=$("$QSTAT_CMD" -fx "$job_id" 2>/dev/null | normalize_qstat_fx)
            reason="job is held and may need release/deletion"
            printf '%s\tHELD\t%s\n' "$job_id" "$reason" >> "$PROBLEM_FILE"
            if [ "$VERBOSE" = true ]; then
                print_job_detail "HELD" "$job_id" "$info" "$reason"
            fi
        done < "$HELD_FILE"
    fi

    if [ "$CHECK_QUEUED" = true ]; then
        select_jobs Q > "$QUEUED_FILE"
        queued_total=$(grep -c . "$QUEUED_FILE" || true)

        while IFS= read -r job_id; do
            [ -z "$job_id" ] && continue
            info=$("$QSTAT_CMD" -fx "$job_id" 2>/dev/null | normalize_qstat_fx)
            select_line=$(printf '%s\n' "$info" | get_attr "Resource_List.select")
            comment=$(printf '%s\n' "$info" | get_attr "comment")

            reasons=""
            requested_nodes=$(printf '%s\n' "$select_line" | extract_requested_nodes)
            missing_nodes=""

            while IFS= read -r req_node; do
                [ -z "$req_node" ] && continue
                if ! node_exists "$req_node"; then
                    missing_nodes="$missing_nodes $req_node"
                fi
            done <<EOF_NODES
$requested_nodes
EOF_NODES

            if [ -n "$(printf '%s' "$missing_nodes" | trim)" ]; then
                missing_node_count=$((missing_node_count + 1))
                reasons="requested node(s) not found in freenodes:$missing_nodes"
            fi

            if printf '%s\n' "$comment" | grep -qiE 'insufficient|cannot satisfy|never run|not running|resources unavailable'; then
                insufficient_count=$((insufficient_count + 1))
                if [ -n "$reasons" ]; then
                    reasons="$reasons; scheduler comment indicates resource issue"
                else
                    reasons="scheduler comment indicates resource issue"
                fi
            fi

            if [ -n "$reasons" ]; then
                printf '%s\tQUEUED\t%s\n' "$job_id" "$reasons" >> "$PROBLEM_FILE"
                if [ "$VERBOSE" = true ]; then
                    print_job_detail "QUEUED" "$job_id" "$info" "$reasons"
                fi
            fi
        done < "$QUEUED_FILE"
    fi

    problem_total=$(grep -c . "$PROBLEM_FILE" || true)

    printf '\n=== SUMMARY ===\n'
    [ "$CHECK_QUEUED" = true ] && printf 'Queued jobs checked: %s\n' "$queued_total"
    [ "$CHECK_HELD" = true ] && printf 'Held jobs checked: %s\n' "$held_total"
    printf 'Flagged jobs total: %s\n' "$problem_total"
    [ "$CHECK_QUEUED" = true ] && printf 'Queued jobs requesting missing node/vnode: %s\n' "$missing_node_count"
    [ "$CHECK_QUEUED" = true ] && printf 'Queued jobs with scheduler resource comments: %s\n' "$insufficient_count"
    [ "$CHECK_HELD" = true ] && printf 'Held jobs flagged: %s\n' "$held_count"

    if [ "$problem_total" -gt 0 ]; then
        printf '\nProblem jobs:\n'
        if [ "$SHOW_ALL_PROBLEM_JOBS" = true ] || [ "$VERBOSE" = true ]; then
            awk -F '\t' '{ printf "  %s [%s] - %s\n", $1, $2, $3 }' "$PROBLEM_FILE"
        else
            awk -F '\t' 'NR <= 25 { printf "  %s [%s] - %s\n", $1, $2, $3 } NR == 26 { print "  ... use --show-all-problem-jobs to print the rest" }' "$PROBLEM_FILE"
        fi
    fi

    printf '\n=== Done ===\n'

    if [ "$EXIT_NONZERO" = true ] && [ "$problem_total" -gt 0 ]; then
        exit 2
    fi
}

main "$@"
