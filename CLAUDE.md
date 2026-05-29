# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**modulecheck** is a bash utility that identifies potentially unnecessary JARs in JBoss/WildFly module definitions. It comments out `<resource-root>` and `<artifact>` entries one at a time in `module.xml` files, runs a Maven test suite after each removal, and reports which JARs can be safely removed.

## Running the Script

```bash
./modulecheck.sh --wildfly-dir /path/to/wildfly --test-dir /path/to/testsuite
./modulecheck.sh --wildfly-dir /path/to/wildfly --test-dir /path/to/testsuite \
    --module-dir modules/system/layers/base --module-dir modules/system/layers/custom
```

Key options:
- `--wildfly-dir <path>` — (required) WildFly installation path; resolved to absolute path internally
- `--test-dir <path>` — (required) directory containing `pom.xml` for the test suite
- `--module-dir <relative-path>` — module directory relative to `--wildfly-dir` (repeatable; default: `modules`). Can be specified multiple times; all directories are searched and their modules are processed together.
- `-t, --test <pattern>` — passed to Maven as `-Dtest=<pattern>`
- `-v, --verbose` — streams Maven output to stdout via `tee` (otherwise log-only)

Results are written to `./modulecheck-results/` with `unnecessary.txt` listing removable entries and `logs/` containing per-entry Maven output.

## Architecture

Single-file script (`check_modules.sh`). No build system, no dependencies beyond standard Unix tools and Maven.

**Core flow:** `find module.xml files → for each file, find uncommented entries via awk → for each entry, backup file, comment out line, run mvn, record result, restore from backup`

**Key design decisions:**
- All file edits use `awk > tmpfile && mv -f tmpfile file` instead of `sed -i` for macOS/Linux portability
- `find_uncommented_entries()` tracks multi-line XML comment state (`in_comment` flag) to skip already-commented `<artifact>` entries
- Signal trap (`EXIT INT TERM HUP`) guarantees module.xml restoration even on Ctrl+C — the `cleanup()` function restores `CURRENT_BACKUP` if set
- Maven command is built as a bash array (`mvn_cmd`) so verbose/non-verbose branches share the same command definition
- `require_arg()` validates that options expecting a value actually received one (not empty, not another flag starting with `-`)

**The `wildfly/` directory is not stored in the repo** — it is provided externally via `--wildfly-dir` at runtime.
