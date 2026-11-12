#!/usr/bin/env bash
# Block copy-pasted production Swift before it lands. A duplicated block means
# a fix made in one copy is missed in the other, which matters most for the
# clipboard privacy and paste paths. lizard is already pinned for the shared
# complexity check, so its duplicate extension adds no new dependency.
# Tests are left out on purpose: their setup repeats so that each test reads
# on its own, and that repetition is not a maintenance risk.
# Usage: DUPLICATION_TIMEOUT=<s> scripts/check-duplication.sh <path>...   (make duplication)
set -euo pipefail

readonly SCANNER=lizard
readonly INSTALL_HINT='mise use -g pipx:lizard'
readonly SCAN_SECONDS="${DUPLICATION_TIMEOUT:?set by make duplication}"
# Complexity and length limits out of reach, so only duplication decides
# this check; function size is judged by the shared complexity check.
readonly UNLIMITED=100000
# lizard prints this section only when its duplicate extension ran; without
# it the scan proved nothing, so the check fails closed.
readonly SECTION_MARKER='^Duplicates$'
# One line per duplicated block lizard reports (default: 70 matching tokens).
readonly BLOCK_MARKER='^Duplicate block:$'
readonly RATE_MARKER='^Total duplicate rate'

if [[ $# -eq 0 ]]; then
    printf 'usage: %s <path>...\n' "$0" >&2
    exit 2
fi

for tool in "$SCANNER" timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '❌ duplication: %s is not installed (lizard: %s)\n' "$tool" "$INSTALL_HINT" >&2
        exit 1
    fi
done

if ! report=$(timeout "$SCAN_SECONDS" "$SCANNER" -Eduplicate --CCN "$UNLIMITED" --length "$UNLIMITED" "$@" 2>&1); then
    printf '❌ duplication: %s failed or timed out after %ss on: %s\n' "$SCANNER" "$SCAN_SECONDS" "$*" >&2
    printf '%s\n' "$report" >&2
    exit 1
fi

if ! grep -q "$SECTION_MARKER" <<<"$report"; then
    printf '❌ duplication: %s printed no duplicate report for: %s\n' "$SCANNER" "$*" >&2
    exit 1
fi

duplicates=$(sed -n "/$SECTION_MARKER/,\$p" <<<"$report")
if grep -q "$BLOCK_MARKER" <<<"$duplicates"; then
    printf '❌ duplication: duplicated Swift blocks; extract the shared code\n' >&2
    printf '%s\n' "$duplicates" >&2
    exit 1
fi

grep "$RATE_MARKER" <<<"$duplicates" || true
printf 'Duplication OK\n'
