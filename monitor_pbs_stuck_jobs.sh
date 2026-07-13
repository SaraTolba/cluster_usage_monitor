#!/usr/bin/env bash
# monitor_pbs_stuck_jobs.sh
# Weekly PBS stuck-job checker.
# Flags queued/held jobs that likely need admin/user action.
#
# QUEUED jobs are checked for:
#   1. requested host=/vnode= names that do not exist in the cluster (freenodes -gco)
#   2. requested per-chunk resources (ncpus/mem/ngpus/gpu_type) that NO SINGLE node can
#      ever satisfy -- e.g. "ncpus=200" when the largest node has 192 cores. Such jobs
#      will never start and the submitting user should be contacted.
#   3. (opt-in, --check-comments) scheduler comment text mentioning a resource problem.
#      Off by default because PBS emits such comments for any job waiting on busy-but-
#      existing resources, so it flags almost every queued job and is not a stuck signal.
#
# HELD jobs are CLASSIFIED rather than flagged wholesale, because "held" is not the same
# as "stuck". A job held only by an unsatisfied run-order dependency (e.g. afterok:<parent>)
# is behaving normally and will start once its parent completes. The categories are:
#   - user/operator/password hold (Hold_Types contains u/o/p) -> actionable (qrls/qdel)
#   - dependency hold (has a depend attribute):
#       * parent missing or finished in a way that can never satisfy the dependency
#         (e.g. afterok parent that failed) -> STUCK, flagged
#       * parent still present / not yet complete -> normal, NOT flagged (counted only)
#   - system hold with no dependency -> flagged for investigation
#   - anything else held -> flagged for investigation
# Dependency-parent lookups can be disabled with --skip-dep-parent-check.
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
INCLUDE_NORMAL_HOLDS=false
SKIP_DEP_PARENT_CHECK=false

usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Checks queued and/or held PBS jobs for conditions that likely require admin/user action.

For QUEUED jobs it compares Resource_List.select against the cluster inventory reported by
"freenodes -gco": it flags requested host=/vnode= names that do not exist, AND per-chunk
resource requests (ncpus/mem/ngpus/gpu_type) that no single node can ever satisfy.

For HELD jobs it classifies the hold. Normal dependency holds (a job waiting on an
afterok/after* parent that is still present) are NOT flagged. Actionable holds
(user/operator/password holds, system holds with no dependency, and dependency holds whose
parent is missing or failed) ARE flagged.

Options:
  -h, --help                 Show this help message
  -Q, --queued-only          Check only queued jobs
  -H, --held-only            Check only held jobs
  -v, --verbose              Print detailed diagnostics for each flagged job
  -s, --summary              Summary output only (this is the default)
  -d, --days DAYS            Only inspect jobs whose qtime is older than DAYS days.
                             (Filtered in-script from qtime, not via qselect.)
  --freenodes-cmd CMD        Override node-list command. Default: "freenodes -gco"
  --exit-nonzero             Exit 2 if any problematic job is found
  --check-comments           Also flag queued jobs whose scheduler comment mentions a
                             resource issue. Off by default: PBS writes such comments for
                             any job waiting on busy resources, so it flags nearly all
                             queued jobs.
  --include-normal-holds     Also list normal (non-stuck) dependency holds in the output.
  --skip-dep-parent-check    Do not look up dependency parents; treat every dependency hold
                             as normal (fewer qstat calls, but misses stuck dependencies).
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

# qstat -fx prints "Name = value" attribute lines (space-indented) and folds long values
# onto continuation lines (tab-indented, and NOT of the form "name = value"). This rewrites
# each attribute so it begins at column 1, and appends folded continuations to it (no
# separator, since PBS folds mid-value), so get_attr can match attributes by prefix.
#
# A line is treated as a NEW attribute only when it looks like "name = " with a real space
# before the '='. This is important: folded Variable_List / Submit_arguments continuations
# look like "PBS_O_LOGNAME=woojoo.jung," or "T=166,..." -- i.e. "name=value" with NO space
# before '=' -- and must be treated as continuations, not as new attributes.
normalize_qstat_fx() {
    awk '
        function flush() { if (have) { print buf; buf=""; have=0 } }
        /^[Jj]ob[[:space:]]+[Ii]d:/ { flush(); print; next }
        /^[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]+=/ {     # new attribute: "Name = value"
            flush()
            s=$0; sub(/^[[:space:]]+/, "", s)
            buf=s; have=1
            next
        }
        {                                                        # folded continuation
            s=$0; sub(/^[[:space:]]+/, "", s)
            if (have) buf=buf s; else print s
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

# Case-insensitive existence check. NODE_FILE is stored lowercased (see main), and the
# feasibility check also lowercases node names, so both node checks agree on case.
node_exists() {
    local node
    node=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
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

# Emit "type<TAB>parent_jobid" for each entry in a depend attribute value.
# depend looks like "afterok:720352.bright04@bright04" or
# "afterok:111.srv:222.srv,afterany:333.srv". @server suffixes are stripped.
parse_depend() {
    awk '
        {
            n=split($0, groups, ",")
            for (g=1; g<=n; g++) {
                grp=groups[g]
                ci=index(grp, ":")
                if (ci==0) continue
                type=substr(grp, 1, ci-1)
                rest=substr(grp, ci+1)
                m=split(rest, ids, ":")
                for (j=1; j<=m; j++) {
                    id=ids[j]
                    sub(/@.*/, "", id)
                    if (id!="") printf "%s\t%s\n", type, id
                }
            }
        }
    '
}

# Given a depend value, return a reason string if a run-order dependency can never be
# satisfied (parent gone, or afterok/afternotok parent finished in the wrong way).
# Returns empty if all after* parents are still present / not yet finished (normal), or if
# the dependency is not a run-order (after*) type we can assess. Tolerant: qstat failures
# for a parent are treated as "parent not found".
check_dependency_parents() {
    local dep="$1"
    local reason="" dtype pid pinfo pstate pexit
    while IFS=$'\t' read -r dtype pid; do
        [ -z "$pid" ] && continue
        case "$dtype" in
            after|afterok|afterany|afternotok) ;;   # run-order deps we can assess
            *) continue ;;
        esac
        pinfo=$("$QSTAT_CMD" -fx "$pid" 2>/dev/null | normalize_qstat_fx)
        if [ -z "$pinfo" ]; then
            # If the child is still held on this parent and the parent is gone, the
            # dependency cannot fire (a successfully-completed parent would have released it).
            reason="${reason:+$reason; }parent $pid not found (dependency $dtype cannot be satisfied)"
            continue
        fi
        pstate=$(printf '%s\n' "$pinfo" | get_attr "job_state")
        pexit=$(printf '%s\n' "$pinfo" | get_attr "Exit_status")
        if [ "$pstate" = "F" ]; then
            if [ "$dtype" = "afterok" ] && [ -n "$pexit" ] && [ "$pexit" != "0" ]; then
                reason="${reason:+$reason; }parent $pid finished with Exit_status=$pexit (afterok never satisfied)"
            elif [ "$dtype" = "afternotok" ] && [ "$pexit" = "0" ]; then
                reason="${reason:+$reason; }parent $pid finished successfully (afternotok never satisfied)"
            fi
        fi
    done < <(printf '%s\n' "$dep" | parse_depend)
    printf '%s' "$reason"
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

# Succeeds if the job is old enough to inspect (or if age is unknown / no --days filter).
job_meets_age() {
    [ -z "$DAYS" ] && return 0
    local age
    age=$(get_job_age_days_from_normalized_info "$1")
    [ "$age" = "unknown" ] && return 0
    [ "$age" -ge "$DAYS" ]
}

# Select all jobs in a given state. Returns qselect's exit status so callers can warn on
# real failures (vs. a legitimately empty result).
select_jobs() {
    local state="$1"
    "$QSELECT_CMD" -s "$state" 2>/dev/null
}

print_job_detail() {
    local tag="$1"
    local job_id="$2"
    local info="$3"
    local reason="$4"
    local age
    age=$(get_job_age_days_from_normalized_info "$info")
    printf '\n=== %s ===\n' "$tag"
    printf 'Job: %s\n' "$job_id"
    printf 'Reason: %s\n' "$reason"
    printf 'Age: %s days\n' "$age"
    printf '%s\n' "$info" | grep -E '^(Job_Name|Job_Owner|job_state|queue|qtime|Hold_Types|depend|Exit_status|comment|Resource_List\.(select|place|nodect|ncpus|mem|walltime)|Resource_List.preempt_targets) = ' | sed 's/^/  /'
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
            --include-normal-holds) INCLUDE_NORMAL_HOLDS=true ;;
            --skip-dep-parent-check) SKIP_DEP_PARENT_CHECK=true ;;
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
    need_cmd tr
    need_cmd sed
    need_cmd date
    need_cmd mktemp

    NODE_CAP_FILE=$(mktemp)
    NODE_FILE=$(mktemp)
    PROBLEM_FILE=$(mktemp)
    NORMALHOLD_FILE=$(mktemp)
    HELD_FILE=$(mktemp)
    QUEUED_FILE=$(mktemp)
    trap 'rm -f "$NODE_CAP_FILE" "$NODE_FILE" "$PROBLEM_FILE" "$NORMALHOLD_FILE" "$HELD_FILE" "$QUEUED_FILE"' EXIT

    load_cluster_capacities > "$NODE_CAP_FILE"
    # NODE_FILE is lowercased so node_exists() (which lowercases its input) is consistent
    # with the feasibility check (which also lowercases node names).
    cut -f1 "$NODE_CAP_FILE" | tr 'A-Z' 'a-z' | sort -u > "$NODE_FILE"
    node_count=$(grep -c . "$NODE_FILE" || true)
    if [ "$node_count" -eq 0 ]; then
        printf 'ERROR: no nodes parsed from: %s\n' "$FREENODES_CMD" >&2
        exit 1
    fi

    printf 'PBS stuck-job check started: %s\n' "$(date)"
    printf 'Node source: %s (%s nodes parsed)\n' "$FREENODES_CMD" "$node_count"
    if [ -n "$DAYS" ]; then
        printf 'Age filter: only jobs older than %s days (by qtime)\n' "$DAYS"
    fi

    held_total=0
    held_checked=0
    held_user=0
    held_system=0
    held_dep_stuck=0
    held_dep_normal=0
    held_other=0

    queued_total=0
    queued_checked=0
    missing_node_count=0
    infeasible_count=0
    insufficient_count=0

    if [ "$CHECK_HELD" = true ]; then
        if ! select_jobs H > "$HELD_FILE"; then
            printf 'WARNING: "%s -s H" returned an error; held-job results may be incomplete\n' "$QSELECT_CMD" >&2
        fi
        held_total=$(grep -c . "$HELD_FILE" || true)

        while IFS= read -r job_id; do
            [ -z "$job_id" ] && continue
            info=$("$QSTAT_CMD" -fx "$job_id" 2>/dev/null | normalize_qstat_fx)
            if [ -z "$info" ]; then
                log_debug "WARN: no qstat -fx output for held job $job_id (skipped)"
                continue
            fi
            job_meets_age "$info" || continue
            held_checked=$((held_checked + 1))

            hold_types=$(printf '%s\n' "$info" | get_attr "Hold_Types")
            depend=$(printf '%s\n' "$info" | get_attr "depend")

            user_or_op=false
            has_system=false
            has_depend=false
            case "$hold_types" in *[uUoOpP]*) user_or_op=true ;; esac
            case "$hold_types" in *[sS]*) has_system=true ;; esac
            [ -n "$(printf '%s' "$depend" | trim)" ] && has_depend=true

            is_problem=true
            tag=""
            reason=""
            if [ "$user_or_op" = true ]; then
                held_user=$((held_user + 1))
                tag="HELD-USER"
                reason="user/operator/password hold (Hold_Types=$hold_types) - may need release (qrls) or deletion (qdel)"
            elif [ "$has_depend" = true ]; then
                dep_reason=""
                if [ "$SKIP_DEP_PARENT_CHECK" = false ]; then
                    dep_reason=$(check_dependency_parents "$depend")
                fi
                if [ -n "$dep_reason" ]; then
                    held_dep_stuck=$((held_dep_stuck + 1))
                    tag="HELD-DEP-STUCK"
                    reason="dependency can never be satisfied ($depend): $dep_reason"
                else
                    held_dep_normal=$((held_dep_normal + 1))
                    tag="HELD-DEP-OK"
                    reason="dependency hold ($depend) - normal; predecessor not yet complete"
                    is_problem=false
                fi
            elif [ "$has_system" = true ]; then
                held_system=$((held_system + 1))
                tag="HELD-SYSTEM"
                reason="system hold (Hold_Types=$hold_types) with no dependency - investigate"
            else
                held_other=$((held_other + 1))
                tag="HELD"
                reason="held (Hold_Types=${hold_types:-unknown}) - investigate"
            fi

            if [ "$is_problem" = true ]; then
                printf '%s\t%s\t%s\n' "$job_id" "$tag" "$reason" >> "$PROBLEM_FILE"
                [ "$VERBOSE" = true ] && print_job_detail "$tag" "$job_id" "$info" "$reason"
            else
                printf '%s\t%s\t%s\n' "$job_id" "$tag" "$reason" >> "$NORMALHOLD_FILE"
                if [ "$INCLUDE_NORMAL_HOLDS" = true ] && [ "$VERBOSE" = true ]; then
                    print_job_detail "$tag" "$job_id" "$info" "$reason"
                fi
            fi
        done < "$HELD_FILE"
    fi

    if [ "$CHECK_QUEUED" = true ]; then
        if ! select_jobs Q > "$QUEUED_FILE"; then
            printf 'WARNING: "%s -s Q" returned an error; queued-job results may be incomplete\n' "$QSELECT_CMD" >&2
        fi
        queued_total=$(grep -c . "$QUEUED_FILE" || true)

        while IFS= read -r job_id; do
            [ -z "$job_id" ] && continue
            info=$("$QSTAT_CMD" -fx "$job_id" 2>/dev/null | normalize_qstat_fx)
            if [ -z "$info" ]; then
                log_debug "WARN: no qstat -fx output for queued job $job_id (skipped)"
                continue
            fi
            job_meets_age "$info" || continue
            queued_checked=$((queued_checked + 1))

            select_line=$(printf '%s\n' "$info" | get_attr "Resource_List.select")
            comment=$(printf '%s\n' "$info" | get_attr "comment")

            reasons=""

            # (1) requested host/vnode names that do not exist
            requested_nodes=$(printf '%s\n' "$select_line" | extract_requested_nodes)
            missing_nodes=""
            while IFS= read -r req_node; do
                [ -z "$req_node" ] && continue
                # Skip unexpanded ranges (e.g. node[001-003]); the feasibility check skips
                # bracketed chunks too, so we do not false-positive them as missing nodes.
                case "$req_node" in *'['*|*']'*) continue ;; esac
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
                    print_job_detail "QUEUED JOB FLAGGED" "$job_id" "$info" "$reasons"
                fi
            fi
        done < "$QUEUED_FILE"
    fi

    problem_total=$(grep -c . "$PROBLEM_FILE" || true)
    normal_hold_total=$(grep -c . "$NORMALHOLD_FILE" || true)

    printf '\n=== SUMMARY ===\n'
    if [ "$CHECK_QUEUED" = true ]; then
        printf 'Queued jobs selected: %s\n' "$queued_total"
        [ -n "$DAYS" ] && printf 'Queued jobs checked (older than %s days): %s\n' "$DAYS" "$queued_checked"
    fi
    if [ "$CHECK_HELD" = true ]; then
        printf 'Held jobs selected: %s\n' "$held_total"
        [ -n "$DAYS" ] && printf 'Held jobs checked (older than %s days): %s\n' "$DAYS" "$held_checked"
    fi
    printf 'Flagged (actionable) jobs total: %s\n' "$problem_total"

    if [ "$CHECK_QUEUED" = true ]; then
        printf '  Queued: requesting missing node/vnode: %s\n' "$missing_node_count"
        printf '  Queued: unsatisfiable resources (contact user): %s\n' "$infeasible_count"
        [ "$CHECK_COMMENTS" = true ] && printf '  Queued: scheduler resource comment: %s\n' "$insufficient_count"
    fi
    if [ "$CHECK_HELD" = true ]; then
        printf '  Held: user/operator/password hold: %s\n' "$held_user"
        printf '  Held: system hold (no dependency): %s\n' "$held_system"
        printf '  Held: unsatisfiable dependency (stuck): %s\n' "$held_dep_stuck"
        printf '  Held: other: %s\n' "$held_other"
        printf 'Normal dependency holds (not flagged): %s\n' "$held_dep_normal"
    fi

    if [ "$problem_total" -gt 0 ]; then
        printf '\nProblem jobs:\n'
        if [ "$SHOW_ALL_PROBLEM_JOBS" = true ] || [ "$VERBOSE" = true ]; then
            awk -F '\t' '{ printf "  %s [%s] - %s\n", $1, $2, $3 }' "$PROBLEM_FILE"
        else
            awk -F '\t' 'NR <= 25 { printf "  %s [%s] - %s\n", $1, $2, $3 } NR == 26 { print "  ... use --show-all-problem-jobs to print the rest" }' "$PROBLEM_FILE"
        fi
    fi

    if [ "$INCLUDE_NORMAL_HOLDS" = true ] && [ "$normal_hold_total" -gt 0 ]; then
        printf '\nNormal dependency holds (informational, not flagged):\n'
        awk -F '\t' '{ printf "  %s [%s] - %s\n", $1, $2, $3 }' "$NORMALHOLD_FILE"
    fi

    printf '\n=== Done ===\n'

    if [ "$EXIT_NONZERO" = true ] && [ "$problem_total" -gt 0 ]; then
        exit 2
    fi
}

main "$@"