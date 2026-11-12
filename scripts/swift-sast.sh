#!/usr/bin/env bash
# Run the repo's semgrep rules (.semgrep-swift.yml) and decide pass or fail
# here instead of with semgrep --strict.
# Why: semgrep's Swift parser lags the language. Newer syntax makes it skip a
# few lines of a file it otherwise parses, and --strict turns each such skip
# into a failed push with no finding. A blanket skip would let a whole
# unparsed file pass unseen, so only short partial-parse gaps are tolerated,
# and each one is printed so it stays visible. Any finding, any other scanner
# error, or a longer gap fails closed.
# Usage: SWIFT_SCAN_TIMEOUT=<s> scripts/swift-sast.sh <path>...   (make swift-sast)
set -euo pipefail

readonly CONFIG=.semgrep-swift.yml
readonly SCAN_SECONDS="${SWIFT_SCAN_TIMEOUT:?set by make swift-sast}"
# Relaxation, with reason: room for a short block of newer syntax, but a
# lost function or type body is longer than this and fails the scan.
readonly MAX_SKIPPED_LINES=15
readonly PARTIAL_PARSE=PartialParsing
# semgrep exits 0 with no findings and 1 with findings (read from the JSON);
# anything higher means the scan itself broke.
readonly MAX_RESULT_EXIT=1

if [[ $# -eq 0 ]]; then
    printf 'usage: %s <path>...\n' "$0" >&2
    exit 2
fi

for tool in semgrep jq timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '❌ swift-sast: %s is not installed\n' "$tool" >&2
        exit 1
    fi
done

stderr_log=$(mktemp "${TMPDIR:-/tmp}/swift-sast.XXXXXX")
trap 'rm -f -- "$stderr_log"' EXIT

# --disable-nosem: an inline `nosemgrep` comment would be an unreviewed
# waiver; an exception must be a reviewed `paths.exclude` in the rule.
status=0
report=$(timeout "$SCAN_SECONDS" semgrep scan --config "$CONFIG" --metrics=off \
    --disable-version-check --disable-nosem --json "$@" 2>"$stderr_log") || status=$?
if [[ "$status" -gt "$MAX_RESULT_EXIT" ]] || ! jq -e '(.results | type == "array") and (.errors | type == "array")' <<<"$report" >/dev/null 2>&1; then
    printf '❌ swift-sast: semgrep failed (exit %s) or returned no report for: %s\n' "$status" "$*" >&2
    tail -n 20 "$stderr_log" >&2
    exit 1
fi

findings=$(jq -r '.results[] | "\(.path):\(.start.line): \(.check_id | split(".") | last): \(.extra.message)"' <<<"$report")
# Errors that are not a partial parse, or a partial parse wider than the limit.
blocking=$(jq -r --arg kind "$PARTIAL_PARSE" --argjson max "$MAX_SKIPPED_LINES" '
    .errors[]
    | if (.type | type) == "array" and .type[0] == $kind
      then .type[1][] | select(.end.line - .start.line + 1 > $max)
           | "\(.path):\(.start.line)-\(.end.line): parser skipped more than \($max) lines"
      else "\(.path // "semgrep"): \(.type | tostring): \(.message)"
      end' <<<"$report")
skipped=$(jq -r --arg kind "$PARTIAL_PARSE" '
    .errors[] | select((.type | type) == "array" and .type[0] == $kind)
    | .type[1][] | "\(.path):\(.start.line)-\(.end.line)"' <<<"$report")

if [[ -n "$skipped" ]]; then
    printf 'swift-sast: parser skipped these spans (newer Swift syntax):\n%s\n' "$skipped" >&2
fi
if [[ -n "$blocking" ]]; then
    printf '❌ swift-sast: scanner errors:\n%s\n' "$blocking" >&2
    exit 1
fi
if [[ -n "$findings" ]]; then
    printf '❌ swift-sast: findings:\n%s\n' "$findings" >&2
    exit 1
fi

printf 'swift-sast: %s files scanned, 0 findings\n' "$(jq '.paths.scanned | length' <<<"$report")"
