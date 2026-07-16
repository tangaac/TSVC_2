#!/bin/bash
#
# perf_bench.sh - TSVB Performance Benchmark Script
#
# Automatically compiles TSVB tests with multiple compiler configs,
# runs perf stat to collect metrics, and generates organized reports.
#
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
COMPILERS=(before cost backend backcost)
TESTS=(s1111 s112 s1112 s125 s127 s128 s252 s254 s255 s257 s276
       s31111 s353 s442 s443 s452 s491 s4112 s4113 s4114 s4117
       vag vas vif)
EVENTS="cycles,instructions,branches,branch-misses,cache-misses,L1-icache-load-misses"
RUNS=3
VARIANT="vec_default"
BASELINE="before"
RESULTS_DIR="perf_results"
MAKEFILE_DIR="makefiles"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Usage
# ============================================================
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

TSVB Performance Benchmark Script

Compiles specified TSVB tests with multiple compiler configurations,
runs perf stat to collect hardware metrics, and generates reports.

Options:
  -c, --compiler NAME   Specify a single compiler config (default: all)
  -t, --test NAME       Specify a single test (default: all)
  -e, --events LIST     Comma-separated perf events (default: $EVENTS)
  -r, --runs N          Number of perf runs per test (default: 3)
  -v, --variant TYPE    Build variant: vec or novec (default: vec)
  --skip-built          Skip tests that already have results
  --clean               Remove existing results directory before running
  -h, --help            Show this help message

Examples:
  $(basename "$0")                          # Run all compilers, all tests
  $(basename "$0") -c before -t s1111      # Single compiler + test
  $(basename "$0") -r 5                    # 5 perf runs per test
  $(basename "$0") -e "cycles,instructions"  # Custom event list
  $(basename "$0") --skip-built            # Only run new tests

Prerequisites:
  - Place Makefile.before, Makefile.cost, Makefile.backend, Makefile.backcost
    in the makefiles/ directory (same as Makefile.GNU format)
  - perf must be available (kernel.perf_event_paranoid = 0 recommended)

Output:
  perf_results/results.csv    - All metrics in CSV format
  perf_results/summary.txt    - Formatted comparison tables
  perf_results/<compiler>/<test>/  - Raw perf output per run
EOF
    exit 0
}

# ============================================================
# Helpers
# ============================================================
fmt_num() {
    # Format a number with K/M suffix for display
    local n=$1
    if (( n >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc)"
    elif (( n >= 1000 )); then
        printf "%.1fK" "$(echo "scale=1; $n / 1000" | bc)"
    else
        printf "%d" "$n"
    fi
}

# Extract a metric value from perf stat output
# perf output lines look like: "  54,321,098  cycles"
extract_metric() {
    local file="$1"
    local metric="$2"
    grep -E "\\b${metric}\\b" "$file" 2>/dev/null | head -1 | awk '{gsub(/,/, "", $1); print $1}' | tr -d '[:space:]'
}

# ============================================================
# Prerequisites check
# ============================================================
check_prereqs() {
    if ! command -v perf &>/dev/null; then
        echo "ERROR: perf not found. Install it (linux-tools-common package)."
        exit 1
    fi

    # Check perf_event_paranoid
    if [[ -f /proc/sys/kernel/perf_event_paranoid ]]; then
        local paranoid
        paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)
        if (( paranoid > 0 )); then
            echo "WARNING: kernel.perf_event_paranoid=$paranoid (should be 0)."
            echo "  Run: echo 0 | sudo tee /proc/sys/kernel/perf_event_paranoid"
        fi
    fi

    # Check compiler makefiles
    for compiler in "${COMPILERS[@]}"; do
        local mf="${SCRIPT_DIR}/${MAKEFILE_DIR}/Makefile.${compiler}"
        if [[ ! -f "$mf" ]]; then
            echo "ERROR: $mf not found."
            echo "Place your compiler config files in the makefiles/ directory."
            exit 1
        fi
    done
    echo "All compiler configs found."
}

# ============================================================
# Build a single test
# ============================================================
build_test() {
    local compiler="$1"
    local test="$2"

    echo "  Building ${test} with ${compiler}..."
    local build_output
    if build_output=$(cd "$SCRIPT_DIR" && make COMPILER="$compiler" TEST="$test" 2>&1); then
        return 0
    else
        echo "  ERROR: Build failed for ${compiler}/${test}"
        echo "$build_output" | tail -20
        return 1
    fi
    return 0
}

# ============================================================
# Run perf for a single test
# ============================================================
run_perf() {
    local compiler="$1"
    local test="$2"
    local run_id="$3"
    local binary="${SCRIPT_DIR}/bin/${compiler}/tsvc_${VARIANT}"
    local result_dir="${SCRIPT_DIR}/${RESULTS_DIR}/${compiler}/${test}"

    mkdir -p "$result_dir"

    if [[ ! -f "$binary" ]]; then
        echo "  ERROR: Binary $binary not found."
        return 1
    fi

    echo "  Running perf ($run_id/$RUNS)..."
    perf stat -e "$EVENTS" -- "$binary" > "${result_dir}/perf_${run_id}.txt" 2>&1 || true
}

# ============================================================
# Parse all perf runs and aggregate
# ============================================================
parse_and_aggregate() {
    local compiler="$1"
    local test="$2"
    local result_dir="${SCRIPT_DIR}/${RESULTS_DIR}/${compiler}/${test}"

    # Parse event list from EVENTS variable
    local event_names=()
    local event_keys=()
    IFS=',' read -r -a event_names <<< "$EVENTS"
    for ev in "${event_names[@]}"; do
        event_keys+=("$(echo "$ev" | tr '-' '_')")
    done

    # Collect values from all runs
    declare -A metrics
    for i in "${!event_names[@]}"; do
        metrics[$i]=""
    done

    local valid_runs=0
    for run_file in "$result_dir"/perf_*.txt; do
        [[ -f "$run_file" ]] || continue
        local has_data=false
        for i in "${!event_names[@]}"; do
            local val
            val=$(extract_metric "$run_file" "${event_names[$i]}")
            if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
                if [[ -z "${metrics[$i]}" ]]; then
                    metrics[$i]="$val"
                else
                    metrics[$i]="${metrics[$i]} $val"
                fi
                has_data=true
            fi
        done
        if $has_data; then
            ((valid_runs++)) || true
        fi
    done

    if (( valid_runs == 0 )); then
        echo "  ERROR: No valid perf data for ${compiler}/${test}"
        return 1
    fi

    # Aggregate: min for cycles (if present), avg for everything else
    local agg=()
    local has_cycles=false
    local cyc_idx=-1
    local instr_idx=-1
    for i in "${!event_names[@]}"; do
        local vals=(${metrics[$i]})
        if [[ "${event_names[$i]}" == "cycles" ]]; then
            has_cycles=true
            cyc_idx=$i
        fi
        if [[ "${event_names[$i]}" == "instructions" ]]; then
            instr_idx=$i
        fi
        if $has_cycles && (( i == cyc_idx )); then
            # cycles: take minimum
            local min=${vals[0]}
            for v in "${vals[@]}"; do
                (( v < min )) && min=$v
            done
            agg+=("$min")
        else
            # others: take average
            local sum=0
            for v in "${vals[@]}"; do
                ((sum += v)) || true
            done
            local avg=$((sum / ${#vals[@]}))
            agg+=("$avg")
        fi
    done

    # Calculate IPC if both cycles and instructions are present
    local ipc="N/A"
    if $has_cycles && (( instr_idx >= 0 && ${agg[$cyc_idx]:-0} > 0 )); then
        ipc=$(echo "scale=4; ${agg[$instr_idx]} / ${agg[$cyc_idx]}" | bc)
    fi

    # Write result line to CSV
    local csv_line="${compiler},${test}"
    for v in "${agg[@]}"; do
        csv_line="${csv_line},${v}"
    done
    csv_line="${csv_line},${ipc}"
    echo "$csv_line" >> "${SCRIPT_DIR}/${RESULTS_DIR}/results.csv.tmp"

    # Store aggregated data for summary generation
    local agg_line="${compiler},${test}"
    for v in "${agg[@]}"; do
        agg_line="${agg_line},${v}"
    done
    agg_line="${agg_line},${ipc}"
    echo "$agg_line" >> "${SCRIPT_DIR}/${RESULTS_DIR}/agg_data.tmp"

    echo "  Done (${valid_runs} runs, IPC=${ipc})"
}

# ============================================================
# Generate summary report
# ============================================================
generate_report() {
    local agg_file="${SCRIPT_DIR}/${RESULTS_DIR}/agg_data.tmp"
    local csv_tmp="${SCRIPT_DIR}/${RESULTS_DIR}/results.csv.tmp"

    # Build event key list
    local event_keys=()
    IFS=',' read -r -a event_keys <<< "$(echo "$EVENTS" | tr '-' '_')"
    local num_events=${#event_keys[@]}

    # Find cycles index
    local cyc_idx=-1
    for i in "${!event_keys[@]}"; do
        if [[ "${event_keys[$i]}" == "cycles" ]]; then
            cyc_idx=$i
            break
        fi
    done

    # field layout: [0]=compiler, [1]=test, [2..num_events+1]=events, [num_events+2]=IPC
    local cyc_field=$((cyc_idx + 2))
    local ipc_field=$((num_events + 2))

    # Build CSV header
    local csv_file="${SCRIPT_DIR}/${RESULTS_DIR}/results.csv"
    local header="compiler,test"
    for key in "${event_keys[@]}"; do
        header="${header},${key}"
    done
    header="${header},IPC,speedup"
    echo "$header" > "$csv_file"

    # Collect baseline cycles for each test
    declare -A baseline_cycles
    while IFS= read -r line; do
        IFS=',' read -r -a fields <<< "$line"
        if [[ "${fields[0]}" == "$BASELINE" ]]; then
            baseline_cycles[${fields[1]}]="${fields[$cyc_field]}"
        fi
    done < "$agg_file"

    # Write CSV with speedup
    while IFS= read -r line; do
        IFS=',' read -r -a fields <<< "$line"
        local speedup="1.00"
        local test_name="${fields[1]}"
        if [[ -n "${baseline_cycles[$test_name]:-}" && "${baseline_cycles[$test_name]}" -gt 0 ]]; then
            speedup=$(echo "scale=2; ${baseline_cycles[$test_name]} / ${fields[$cyc_field]}" | bc)
        fi
        echo "${line},${speedup}" >> "$csv_file"
    done < "$agg_file"

    # Build short labels for table columns
    local short_labels=()
    for key in "${event_keys[@]}"; do
        case "$key" in
            cycles) short_labels+=("cycles") ;;
            instructions) short_labels+=("instrs") ;;
            branches) short_labels+=("branches") ;;
            branch_misses) short_labels+=("br-miss") ;;
            cache_misses) short_labels+=("cache-miss") ;;
            L1_icache_load_misses) short_labels+=("icache-miss") ;;
            *) short_labels+=("$key") ;;
        esac
    done

    # Build dynamic printf format: compiler col + event cols + IPC + speedup
    local header_fmt="%-12s|"
    local sep_fmt="%-12s-+"
    local data_fmt="%-12s|"
    for _ in "${event_keys[@]}"; do
        header_fmt="${header_fmt} %-9s|"
        sep_fmt="${sep_fmt}%-9s-+"
        data_fmt="${data_fmt} %-9s|"
    done
    header_fmt="${header_fmt} %-7s| %s"
    sep_fmt="${sep_fmt}%-7s-+%s"
    data_fmt="${data_fmt} %-7s| %sx"

    # Generate summary table
    local summary_file="${SCRIPT_DIR}/${RESULTS_DIR}/summary.txt"
    > "$summary_file"

    {
        echo "TSVB Performance Benchmark Summary"
        echo "==================================="
        echo "Baseline: ${BASELINE} | Variant: ${VARIANT} | Runs per test: ${RUNS}"
        echo "Events: ${EVENTS}"
        echo ""

        for test in "${TESTS[@]}"; do
            echo "=== ${test} ==="
            # Print header row
            local header_args=("Compiler")
            for lbl in "${short_labels[@]}"; do header_args+=("$lbl"); done
            header_args+=("IPC" "speedup")
            printf "$header_fmt" "${header_args[@]}"
            echo ""

            local sep_args=("------------")
            for _ in "${short_labels[@]}"; do sep_args+=("---------"); done
            sep_args+=("-------" "--------")
            printf "$sep_fmt" "${sep_args[@]}"
            echo ""

            while IFS= read -r line; do
                IFS=',' read -r -a fields <<< "$line"
                local t="${fields[1]}"
                [[ "$t" != "$test" ]] && continue
                # Look up speedup from CSV
                local csv_line
                csv_line=$(grep "^${fields[0]},${t}," "$csv_file" | head -1)
                local speedup="1.00"
                if [[ -n "$csv_line" ]]; then
                    IFS=',' read -r -a csv_fields <<< "$csv_line"
                    speedup="${csv_fields[-1]}"
                fi
                local data_args=("${fields[0]}")
                for i in $(seq 2 $((num_events + 1))); do
                    data_args+=("$(fmt_num "${fields[$i]}")")
                done
                data_args+=("${fields[$ipc_field]}" "$speedup")
                printf "$data_fmt" "${data_args[@]}"
                echo ""
            done < "$agg_file"
            echo ""
        done
    } | tee "$summary_file"

    echo ""
    echo "Results written to:"
    echo "  ${csv_file}"
    echo "  ${summary_file}"
}

# ============================================================
# Main
# ============================================================
main() {
    # Parse arguments
    local selected_compilers=("${COMPILERS[@]}")
    local selected_tests=("${TESTS[@]}")
    local skip_built=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--compiler)
                selected_compilers=("$2")
                shift 2
                ;;
            -t|--test)
                selected_tests=("$2")
                shift 2
                ;;
            -e|--events)
                EVENTS="$2"
                shift 2
                ;;
            -r|--runs)
                RUNS="$2"
                shift 2
                ;;
            -v|--variant)
                VARIANT="$2"
                shift 2
                ;;
            --skip-built)
                skip_built=true
                shift
                ;;
            --clean)
                rm -rf "${SCRIPT_DIR}/${RESULTS_DIR}"
                echo "Cleaned ${RESULTS_DIR}/"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    cd "$SCRIPT_DIR"

    echo "TSVB Performance Benchmark"
    echo "=========================="
    echo "Compilers: ${selected_compilers[*]}"
    echo "Tests: ${#selected_tests[@]}"
    echo "Events: $EVENTS"
    echo "Runs: $RUNS per test"
    echo "Variant: $VARIANT"
    echo ""

    check_prereqs

    # Clean previous run temp files
    rm -f "${SCRIPT_DIR}/${RESULTS_DIR}/agg_data.tmp"
    rm -f "${SCRIPT_DIR}/${RESULTS_DIR}/results.csv.tmp"

    local total=0
    local done_count=0

    for compiler in "${selected_compilers[@]}"; do
        for test in "${selected_tests[@]}"; do
            ((total++)) || true
        done
    done

    for compiler in "${selected_compilers[@]}"; do
        echo ""
        echo "============================================"
        echo "Compiler: ${compiler}"
        echo "============================================"

        # Clean build for this compiler
        (cd "$SCRIPT_DIR" && make clean COMPILER="$compiler" >/dev/null 2>&1 || true)

        for test in "${selected_tests[@]}"; do
            ((done_count++)) || true
            echo ""
            echo "[$done_count/$total] ${compiler} / ${test}"

            local result_dir="${SCRIPT_DIR}/${RESULTS_DIR}/${compiler}/${test}"
            if $skip_built && [[ -d "$result_dir" ]] && \
               [[ $(find "$result_dir" -name 'perf_*.txt' | wc -l) -ge "$RUNS" ]]; then
                echo "  Skipping (already built)"
                # Re-aggregate from existing files
                parse_and_aggregate "$compiler" "$test"
                continue
            fi

            # Build
            if ! build_test "$compiler" "$test"; then
                echo "  SKIPPED: build failed"
                continue
            fi

            # Run perf
            local success_runs=0
            for ((run=1; run<=RUNS; run++)); do
                run_perf "$compiler" "$test" "$run"
            done

            # Parse and aggregate
            parse_and_aggregate "$compiler" "$test" || true
        done
    done

    echo ""
    echo "Generating reports..."
    generate_report

    # Cleanup temp files
    rm -f "${SCRIPT_DIR}/${RESULTS_DIR}/agg_data.tmp"
    rm -f "${SCRIPT_DIR}/${RESULTS_DIR}/results.csv.tmp"

    echo ""
    echo "Benchmark complete!"
}

main "$@"
