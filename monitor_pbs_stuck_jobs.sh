#!/usr/bin/env bash
# monitor_pbs_stuck_jobs.sh
# Weekly PBS stuck-job checker.
# Flags queued/held jobs that likely need admin/user action. For queued jobs it checks:
#   1. requested host=/vnode= names that do not exist in the cluster (freenodes -gco)
#   2. requested per-chunk resources (ncpus/mem/ngpus/gpu_type) that NO SINGLE node can
#      ever satisfy -- e.g. "ncpus=200" when the largest node has 192 cores. Such jobs
#      will never start and the submitting user should be contacted.
#   3. (opt-in, --check-comments) scheduler comment text mentioning a resource problem.
#      Off by default because PBS emits such comments for any job waiting on busy-but-
#      existing resources, so it flags almost every queued job and is not a stuck signal.
#
# Resource feasibility uses each node's TOTAL capacity (not currently-free), because the
# question is "can this ever run", not "can it run right now". Offline nodes are therefore
# kept in the list -- an offline node still counts toward what is theoretically satisfiable.

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
CHECK_COMMENTS=false

usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Checks queued and/or held PBS jobs for conditions that likely require admin/user action.
For queued jobs it compares Resource_List.select against the cluster inventory reported by
"freenodes -gco": it flags requested host=/vnode= names that do not exist, AND per-chunk
resource requests (ncpus/mem/ngpus/gpu_type) that no single node can ever satisfy.

Options:
  -h, --help                 Show this help message
  -Q, --queued-only          Check only queued jobs
  -H, --held-only            Check only held jobs
  -v, --verbose              Print detailed diagnostics for each flagged job
  -d, --days DAYS            Only inspect queued/held jobs older than DAYS days
  --freenodes-cmd CMD        Override node-list command. Default: "freenodes -gco"
  --exit-nonzero             Exit 2 if any problematic job is found
  --check-comments           Also flag jobs whose scheduler comment mentions a resource
                             issue. Off by default: PBS writes such comments for any job
                             waiting on busy resources, so it flags nearly all queued jobs.
  --show-all-problem-jobs    Print all flagged job IDs in summary

Examples:
  $0
  $0 -Q -d 7 -v
  $0 --exit-nonzero > pbs_stuck_jobs.txt
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

# qstat -fx prints "Name = value" attribute lines (indented) and folds long values onto
# continuation lines (more-indented, no "name ="). This rewrites each attribute so it
# begins at column 1, and appends folded continuations to it (no separator, since PBS
# folds mid-value), so get_attr can match attributes by prefix.
normalize_qstat_fx() {
    awk '
        function flush() { if (have) { print buf; buf=""; have=0 } }
        /^[Jj]ob[[:space:]]+[Ii]d:/ { flush(); print; next }
        /^[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*=/ {     # new attribute
            flush()
            s=$0; sub(/^[[:space:]]+/, "", s)
            buf=s; have=1
            next
        }
        {                                                         # folded continuation
            s=$0; sub(/^[[:space:]]+/, "", s)
            if (have) buf=buf s; else print
        }
        END { flush() }
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

# Parse per-node capacity from freenodes -gco into a TSV:
#   name <TAB> state <TAB> ncpus_total <TAB> mem_total_kb <TAB> gpu_type <TAB> ngpus_total
# Columns expected: NODE QUEUE STATE MEM CPU NCPUS GPU NGPUS
# MEM/NCPUS/NGPUS columns are "used/total"; we keep the TOTAL (after the slash).
load_cluster_capacities() {
    local output
    if ! output=$(eval "$FREENODES_CMD" 2>/dev/null); then
        printf 'ERROR: failed to run node-list command: %s\n' "$FREENODES_CMD" >&2
        exit 1
    fi

    printf '%s\n' "$output" |
        awk '
            function to_kb(val, unit,   n) {
                n = val + 0
                if (unit == "kb") return int(n)
                if (unit == "mb") return int(n*1024)
                if (unit == "gb") return int(n*1048576)
                if (unit == "tb") return int(n*1073741824)
                if (unit == "b" || unit == "") return int(n/1024)
                return int(n*1048576)
            }
            NF == 0 { next }
            /^[[:space:]]*[-=]+[[:space:]]*$/ { next }
            NR == 1 && tolower($0) ~ /(node|host|vnode)/ { next }
            {
                name=$1; gsub(/[,;:]+$/,"",name)
                if (name=="" || name ~ /^#/ || tolower(name) ~ /^(node|host|vnode)$/) next
                state=tolower($3)
                mem=$4; sub(/.*\//,"",mem)
                u=mem; sub(/^[0-9.]+/,"",u); sub(/[a-zA-Z]+$/,"",mem)
                memkb=to_kb(mem, tolower(u))
                ncpus=$6; sub(/.*\//,"",ncpus); ncpus+=0
                gtype=$7
                ngpus=$8; sub(/.*\//,"",ngpus); if (ngpus=="--"||ngpus=="") ngpus=0; ngpus+=0
                printf "%s\t%s\t%d\t%d\t%s\t%d\n", name, state, ncpus, memkb, tolower(gtype), ngpus
            }
        ' |
        sort -u
}

node_exists() {
    local node="$1"
    grep -Fxq "$node" "$NODE_FILE"
}

# Extract explicitly requested host/vnode names from Resource_List.select.
# Uses 2-arg match (POSIX awk) so it works under mawk/BWK awk as well as gawk.
# host=node[001-003] is captured as-is; range expansion is intentionally not guessed.
extract_requested_nodes() {
    awk '
        {
            s=$0
            while (match(s, /(host|vnode)=[^:+,[:space:]]+/)) {
                tok=substr(s, RSTART, RLENGTH)
                sub(/^(host|vnode)=/, "", tok)
                print tok
                s=substr(s, RSTART + RLENGTH)
            }
        }
    ' | sort -u
}

# Given a Resource_List.select string, print a human-readable reason if any chunk can
# never be placed on a single node in the cluster; print nothing if every chunk is
# satisfiable. Uses TOTAL per-node capacity from NODE_CAP_FILE.
# Conservative: chunks containing unexpanded ranges ([..]) are skipped, and a chunk is
# only flagged when no single node satisfies ALL of its resources simultaneously.
check_resource_feasibility() {
    local select_str="$1"
    [ -z "$select_str" ] && return 0
    awk -F'\t' -v sel="$select_str" '
        function to_kb(val, unit,   n) {
            n = val + 0
            if (unit == "kb") return int(n)
            if (unit == "mb") return int(n*1024)
            if (unit == "gb") return int(n*1048576)
            if (unit == "tb") return int(n*1073741824)
            if (unit == "b" || unit == "") return int(n/1024)
            return int(n*1048576)
        }
        { nn++; lname[nn]=tolower($1); ncpus[nn]=$3+0; memkb[nn]=$4+0; gtype[nn]=tolower($5); ngpus[nn]=$6+0 }
        END {
            nc = split(sel, chunks, "[+]")
            reason=""
            for (c=1; c<=nc; c++) {
                chunk=chunks[c]
                if (chunk ~ /[][]/) continue                 # unexpanded range; do not guess
                rncpus=0; rmemkb=0; rngpus=0; rgtype=""; pin=""; havereq=0
                m=split(chunk, toks, ":")
                for (t=1; t<=m; t++) {
                    tok=toks[t]
                    if (t==1 && tok ~ /^[0-9]+$/) continue   # chunk multiplier
                    if (tok ~ /^ncpus=/)         { v=tok; sub(/^ncpus=/,"",v); rncpus=v+0; havereq=1 }
                    else if (tok ~ /^mem=/)      { v=tolower(tok); sub(/^mem=/,"",v); u=v; sub(/^[0-9.]+/,"",u); sub(/[a-z]+$/,"",v); rmemkb=to_kb(v,u); havereq=1 }
                    else if (tok ~ /^ngpus=/)    { v=tok; sub(/^ngpus=/,"",v); rngpus=v+0; havereq=1 }
                    else if (tok ~ /^gpu_type=/) { v=tolower(tok); sub(/^gpu_type=/,"",v); rgtype=v; havereq=1 }
                    else if (tok ~ /^host=/)     { v=tolower(tok); sub(/^host=/,"",v); pin=v; havereq=1 }
                    else if (tok ~ /^vnode=/)    { v=tolower(tok); sub(/^vnode=/,"",v); pin=v; havereq=1 }
                }
                if (!havereq) continue

                feasible=0; anyc=0; gtype_present=0; pin_found=0
                best_ncpus=-1; best_memkb=-1; best_ngpus=-1
                for (i=1; i<=nn; i++) {
                    if (pin!="") { if (lname[i]!=pin) continue; pin_found=1 }
                    if (rgtype!="") { if (gtype[i]!=rgtype) continue; gtype_present=1 }
                    anyc=1
                    if (ncpus[i]>best_ncpus) best_ncpus=ncpus[i]
                    if (memkb[i]>best_memkb) best_memkb=memkb[i]
                    if (ngpus[i]>best_ngpus) best_ngpus=ngpus[i]
                    if (ncpus[i]>=rncpus && memkb[i]>=rmemkb && ngpus[i]>=rngpus) { feasible=1; break }
                }
                if (feasible) continue
                if (pin!="" && !pin_found) continue          # nonexistent pin -> name check handles it
                cr=""
                if (rgtype!="" && !gtype_present) {
                    cr="gpu_type=" rgtype " not present in cluster"
                } else if (anyc==0) {
                    continue
                } else {
                    if (rncpus>best_ncpus) cr=cr (cr?"; ":"") "ncpus=" rncpus " > max per-node " best_ncpus
                    if (rmemkb>best_memkb) cr=cr (cr?"; ":"") "mem=" int(rmemkb/1048576) "gb > max per-node " int(best_memkb/1048576) "gb"
                    if (rngpus>best_ngpus) cr=cr (cr?"; ":"") "ngpus=" rngpus " > max per-node " best_ngpus (rgtype?" for gpu_type=" rgtype:"")
                    if (cr=="") cr="no single node satisfies the combined resources in one chunk"
                }
                reason=reason (reason?"; ":"") "chunk " c " (" cr ")"
            }
            if (reason!="") print reason
        }
    ' "$NODE_CAP_FILE"
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
            -h|--help) usage; exit 0 ;;
            -Q|--queued-only) CHECK_HELD=false ;;
            -H|--held-only) CHECK_QUEUED=false ;;
            -v|--verbose) VERBOSE=true ;;
            -s|--summary) VERBOSE=false ;;
            -d|--days)
                shift
                if [ "${1:-}" = "" ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
                    printf 'ERROR: --days requires a positive integer\n' >&2
                    exit 1
                fi
                DAYS="$1" ;;
            --freenodes-cmd)
                shift
                if [ "${1:-}" = "" ]; then
                    printf 'ERROR: --freenodes-cmd requires a command string\n' >&2
                    exit 1
                fi
                FREENODES_CMD="$1" ;;
            --exit-nonzero) EXIT_NONZERO=true ;;
            --check-comments) CHECK_COMMENTS=true ;;
            --show-all-problem-jobs) SHOW_ALL_PROBLEM_JOBS=true ;;
            *)
                printf 'ERROR: unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1 ;;
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
    need_cmd cut
    need_cmd mktemp

    NODE_CAP_FILE=$(mktemp)
    NODE_FILE=$(mktemp)
    PROBLEM_FILE=$(mktemp)
    HELD_FILE=$(mktemp)
    QUEUED_FILE=$(mktemp)
    trap 'rm -f "$NODE_CAP_FILE" "$NODE_FILE" "$PROBLEM_FILE" "$HELD_FILE" "$QUEUED_FILE"' EXIT

    load_cluster_capacities > "$NODE_CAP_FILE"
    cut -f1 "$NODE_CAP_FILE" | sort -u > "$NODE_FILE"
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
    infeasible_count=0
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

            # (1) requested host/vnode names that do not exist
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

            # (2) requested resources that no single node can ever satisfy
            feasibility=$(check_resource_feasibility "$select_line")
            if [ -n "$feasibility" ]; then
                infeasible_count=$((infeasible_count + 1))
                if [ -n "$reasons" ]; then
                    reasons="$reasons; unsatisfiable resources -> CONTACT USER: $feasibility"
                else
                    reasons="unsatisfiable resources -> CONTACT USER: $feasibility"
                fi
            fi

            # (3) scheduler comment indicating a resource problem (opt-in; off by default).
            # PBS writes "Insufficient amount of resource ..." for ANY job that is merely
            # waiting for busy-but-existing resources, so by itself it is not a stuck signal.
            if [ "$CHECK_COMMENTS" = true ]; then
                if printf '%s\n' "$comment" | grep -qiE 'insufficient|cannot satisfy|never run|not running|resources unavailable'; then
                    insufficient_count=$((insufficient_count + 1))
                    if [ -n "$reasons" ]; then
                        reasons="$reasons; scheduler comment indicates resource issue"
                    else
                        reasons="scheduler comment indicates resource issue"
                    fi
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
    [ "$CHECK_QUEUED" = true ] && printf 'Queued jobs requesting unsatisfiable resources (contact user): %s\n' "$infeasible_count"
    [ "$CHECK_QUEUED" = true ] && [ "$CHECK_COMMENTS" = true ] && printf 'Queued jobs with scheduler resource comments: %s\n' "$insufficient_count"
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