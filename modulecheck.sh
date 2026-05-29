#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
WILDFLY_DIR=""
MODULE_DIRS=()
TEST_DIR=""
RESULTS_DIR="./modulecheck-results"
VERBOSE=false
TEST_FILTER=""
CURRENT_BACKUP=""
CURRENT_MODULE=""
TOTAL_MODULES=0
TOTAL_MODULES_WITH_ENTRIES=0
TOTAL_MODULES_SKIPPED=0
TOTAL_ENTRIES_TESTED=0
TOTAL_UNNECESSARY=0
TOTAL_NEEDED=0
START_TIME=""

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME --wildfly-dir <path> --test-dir <path> [--module-dir <relative-path> ...]

Identify potentially unnecessary JARs in JBoss/WildFly module definitions by
commenting out each <resource-root> and <artifact> entry one at a time and
running a Maven test suite.

Options:
  --wildfly-dir <path>          Path to the WildFly installation (required)
  --test-dir <path>             Directory containing pom.xml for the test suite (required)
  --module-dir <relative-path>  Module directory relative to --wildfly-dir (repeatable; default: modules)
  -t, --test <pattern>           Test filter passed to Maven as -Dtest=<pattern>
  -v, --verbose                 Show Maven test output as it runs
  --help, -h                    Show this help message

Results are written to $RESULTS_DIR/
EOF
    exit 0
}

require_arg() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "Error: $1 requires a value." >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wildfly-dir)
                require_arg "$1" "${2-}"
                WILDFLY_DIR="$2"
                shift 2
                ;;
            --module-dir)
                require_arg "$1" "${2-}"
                MODULE_DIRS+=("$2")
                shift 2
                ;;
            --test-dir)
                require_arg "$1" "${2-}"
                TEST_DIR="$2"
                shift 2
                ;;
            -t|--test)
                require_arg "$1" "${2-}"
                TEST_FILTER="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                echo "Run '$SCRIPT_NAME --help' for usage." >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$WILDFLY_DIR" ]]; then
        echo "Error: --wildfly-dir is required." >&2
        exit 1
    fi
    if [[ ! -d "$WILDFLY_DIR" ]]; then
        echo "Error: WildFly directory does not exist: $WILDFLY_DIR" >&2
        exit 1
    fi
    WILDFLY_DIR="$(cd "$WILDFLY_DIR" && pwd)"
    if [[ -z "$TEST_DIR" ]]; then
        echo "Error: --test-dir is required." >&2
        exit 1
    fi
    if [[ ! -d "$TEST_DIR" ]]; then
        echo "Error: Test directory does not exist: $TEST_DIR" >&2
        exit 1
    fi
    TEST_DIR="$(cd "$TEST_DIR" && pwd)"
    if [[ ! -f "$TEST_DIR/pom.xml" ]]; then
        echo "Error: No pom.xml found in test directory: $TEST_DIR" >&2
        exit 1
    fi

    if [[ ${#MODULE_DIRS[@]} -eq 0 ]]; then
        MODULE_DIRS=("modules")
    fi
    for i in "${!MODULE_DIRS[@]}"; do
        MODULE_DIRS[$i]="$WILDFLY_DIR/${MODULE_DIRS[$i]}"
        if [[ ! -d "${MODULE_DIRS[$i]}" ]]; then
            echo "Error: Module directory does not exist: ${MODULE_DIRS[$i]}" >&2
            exit 1
        fi
    done
}

cleanup() {
    set_title ""
    if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" && -n "$CURRENT_MODULE" ]]; then
        echo ""
        echo "Restoring $CURRENT_MODULE from backup..."
        cp "$CURRENT_BACKUP" "$CURRENT_MODULE"
        rm -f "$CURRENT_BACKUP"
        echo "All module files have been restored."
        CURRENT_BACKUP=""
        CURRENT_MODULE=""
    fi
}

trap cleanup EXIT INT TERM HUP

find_uncommented_entries() {
    local file="$1"
    awk '
        {
            line = $0

            if (in_comment) {
                if (index(line, "-->") > 0) {
                    in_comment = 0
                }
                next
            }

            if (line ~ /<!--.*-->/) {
                next
            }

            if (index(line, "<!--") > 0) {
                in_comment = 1
                next
            }

            if (line ~ /<resource-root / || line ~ /<artifact /) {
                print NR
            }
        }
    ' "$file"
}

comment_out_line() {
    local file="$1"
    local line_num="$2"
    local tmpfile
    tmpfile=$(mktemp)
    awk -v n="$line_num" '
        NR == n {
            match($0, /^[[:space:]]*/);
            indent = substr($0, 1, RLENGTH);
            print indent "<!-- removed -->";
            next
        }
        { print }
    ' "$file" > "$tmpfile" && mv -f "$tmpfile" "$file"
}

extract_entry_description() {
    local file="$1"
    local line_num="$2"
    local line
    line=$(sed -n "${line_num}p" "$file")
    if [[ "$line" == *"<resource-root"* ]]; then
        echo "$line" | grep -oE 'path="[^"]*"' | sed 's/^path="//; s/"$//'
    elif [[ "$line" == *"<artifact"* ]]; then
        echo "$line" | grep -oE 'name="[^"]*"' | sed 's/^name="//; s/"$//'
    fi
}

extract_module_name() {
    local file="$1"
    grep -oE 'module name="[^"]*"' "$file" | head -1 | sed 's/module name="//; s/"//'
}

set_title() {
    printf '\033]0;%s\007' "$1" 2>/dev/null
}

format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))
    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

main() {
    parse_args "$@"

    START_TIME=$(date +%s)
    mkdir -p "$RESULTS_DIR/logs"
    : > "$RESULTS_DIR/unnecessary.txt"
    : > "$RESULTS_DIR/summary.txt"

    echo "========================================================================"
    echo "  Module Check — Unnecessary JAR Detection"
    echo "========================================================================"
    echo "  WildFly dir:   $WILDFLY_DIR"
    local label="  Module dir(s): "
    for dir in "${MODULE_DIRS[@]}"; do
      echo "$label$dir"
      label="                 "
    done
    echo "  Test dir:      $TEST_DIR"
    echo "  Results:       $RESULTS_DIR/"
    echo "  Started:       $(date)"
    echo "========================================================================"
    echo ""

    local module_files
    module_files=$(mktemp)
    find "${MODULE_DIRS[@]}" -name "module.xml" -type f | sort > "$module_files"
    TOTAL_MODULES=$(wc -l < "$module_files" | tr -d ' ')

    local module_index=0
    while IFS= read -r module_file; do
        module_index=$((module_index + 1))

        local line_numbers
        line_numbers=$(find_uncommented_entries "$module_file")

        if [[ -z "$line_numbers" ]]; then
            TOTAL_MODULES_SKIPPED=$((TOTAL_MODULES_SKIPPED + 1))
            continue
        fi

        local entry_count
        entry_count=$(echo "$line_numbers" | wc -l | tr -d ' ')
        TOTAL_MODULES_WITH_ENTRIES=$((TOTAL_MODULES_WITH_ENTRIES + 1))

        local module_name
        module_name=$(extract_module_name "$module_file")

        echo "----------------------------------------------------------------------"
        echo "[Module $module_index/$TOTAL_MODULES] $module_name ($entry_count entries)"
        echo "  File: $module_file"
        echo "----------------------------------------------------------------------"

        local entry_index=0
        while IFS= read -r line_num; do
            entry_index=$((entry_index + 1))
            TOTAL_ENTRIES_TESTED=$((TOTAL_ENTRIES_TESTED + 1))

            local entry_desc
            entry_desc=$(extract_entry_description "$module_file" "$line_num")

            set_title "[module $module_index/$TOTAL_MODULES] [artifact $entry_index/$entry_count] $module_name — $entry_desc"
            printf "  [%3d/%-3d] TESTING     %s\n" "$entry_index" "$entry_count" "$entry_desc"

            CURRENT_MODULE="$module_file"
            CURRENT_BACKUP="${module_file}.modulecheck.bak"
            cp "$module_file" "$CURRENT_BACKUP"

            comment_out_line "$module_file" "$line_num"

            local log_slug
            log_slug=$(echo "$module_name" | tr '.' '-')
            local log_file="$RESULTS_DIR/logs/${log_slug}_line${line_num}.log"

            local mvn_cmd=(mvn -f "$TEST_DIR/pom.xml" -Dtest="$TEST_FILTER" -Djboss.home="$WILDFLY_DIR" -Djboss.install.dir="$WILDFLY_DIR" clean verify)
            local test_start
            test_start=$(date +%s)
            local test_result=0
            if [[ "$VERBOSE" == true ]]; then
                "${mvn_cmd[@]}" 2>&1 | tee "$log_file" || test_result=$?
            else
                "${mvn_cmd[@]}" > "$log_file" 2>&1 || test_result=$?
            fi
            local test_end
            test_end=$(date +%s)
            local test_duration=$((test_end - test_start))

            if [[ $test_result -eq 0 ]]; then
                TOTAL_UNNECESSARY=$((TOTAL_UNNECESSARY + 1))
                printf "  [%3d/%-3d] UNNECESSARY %s  (%s)\n" "$entry_index" "$entry_count" "$entry_desc" "$(format_duration $test_duration)"
                echo "$module_file:$line_num: $entry_desc" >> "$RESULTS_DIR/unnecessary.txt"
            else
                TOTAL_NEEDED=$((TOTAL_NEEDED + 1))
                printf "  [%3d/%-3d] NEEDED      %s  (%s)\n" "$entry_index" "$entry_count" "$entry_desc" "$(format_duration $test_duration)"
            fi

            cp "$CURRENT_BACKUP" "$module_file"
            rm -f "$CURRENT_BACKUP"
            CURRENT_BACKUP=""
            CURRENT_MODULE=""

        done <<< "$line_numbers"

        echo ""
    done < "$module_files"

    rm -f "$module_files"

    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    echo ""
    echo "========================================================================"
    echo "                     MODULE CHECK SUMMARY"
    echo "========================================================================"
    echo "  Total modules scanned:       $TOTAL_MODULES"
    echo "  Modules with entries:        $TOTAL_MODULES_WITH_ENTRIES"
    echo "  Modules skipped (0 entries): $TOTAL_MODULES_SKIPPED"
    echo "  Total entries tested:        $TOTAL_ENTRIES_TESTED"
    echo "    Needed (tests failed):     $TOTAL_NEEDED"
    echo "    Unnecessary (tests pass):  $TOTAL_UNNECESSARY"
    echo "  Total time:                  $(format_duration $total_duration)"
    echo "========================================================================"

    if [[ $TOTAL_UNNECESSARY -gt 0 ]]; then
        echo ""
        echo "Potentially unnecessary entries:"
        cat "$RESULTS_DIR/unnecessary.txt"
    fi

    echo ""
    echo "Full results: $RESULTS_DIR/unnecessary.txt"
    echo "Maven logs:   $RESULTS_DIR/logs/"

    {
        echo "Module Check Summary — $(date)"
        echo "WildFly dir:  $WILDFLY_DIR"
        for dir in "${MODULE_DIRS[@]}"; do
            echo "Module dir:   $dir"
        done
        echo "Test dir:     $TEST_DIR"
        echo ""
        echo "Total modules scanned:       $TOTAL_MODULES"
        echo "Modules with entries:        $TOTAL_MODULES_WITH_ENTRIES"
        echo "Modules skipped (0 entries): $TOTAL_MODULES_SKIPPED"
        echo "Total entries tested:        $TOTAL_ENTRIES_TESTED"
        echo "  Needed (tests failed):     $TOTAL_NEEDED"
        echo "  Unnecessary (tests pass):  $TOTAL_UNNECESSARY"
        echo "Total time:                  $(format_duration $total_duration)"
    } > "$RESULTS_DIR/summary.txt"
}

main "$@"
