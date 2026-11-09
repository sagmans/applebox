#!/usr/bin/env bash
# Query SwiftPM's exact Git revisions because scanners can skip Package.resolved.
set -euo pipefail

readonly LOCKFILE=Package.resolved
readonly ADVISORY_URL=https://api.osv.dev/v1/querybatch
readonly CONNECT_SECONDS=5
readonly REQUEST_SECONDS=30

if ! request=$(jq -ce '
    .pins | select(type == "array" and length > 0)
    | map(.state.revision | select(type == "string" and test("^[0-9a-f]{40}$")))
    | {queries: map({commit: .})}
' "$LOCKFILE") || ! pin_count=$(jq -er '.pins | length' "$LOCKFILE"); then
    printf 'Cannot read Swift dependency pins from %s\n' "$LOCKFILE" >&2
    exit 1
fi

if ! jq -e --argjson count "$pin_count" '.queries | length == $count' <<<"$request" >/dev/null; then
    printf 'Every dependency in %s needs a pinned Git revision\n' "$LOCKFILE" >&2
    exit 1
fi

# A partial or malformed response cannot clear a dependency for push.
if ! response=$(curl --disable --silent --show-error --fail --proto '=https' \
    --connect-timeout "$CONNECT_SECONDS" --max-time "$REQUEST_SECONDS" \
    --header 'Content-Type: application/json' --data-binary "$request" "$ADVISORY_URL") ||
    ! findings=$(jq -er --argjson count "$pin_count" '
        .results | select(type == "array" and length == $count)
        | select(all(.[]; type == "object" and (keys - ["vulns"] | length == 0)
            and (if has("vulns") then .vulns | type == "array"
                and all(.[]; .id | type == "string" and length > 0) else true end)))
        | map(.vulns[]? | .id)
        | join(", ")
    ' <<<"$response"); then
    printf 'Advisory lookup failed or did not cover all %s Swift pins\n' "$pin_count" >&2
    exit 1
fi

if [[ -n "$findings" ]]; then
    printf 'Swift dependency advisories: %s\n' "$findings" >&2
    exit 1
fi
printf 'Checked %s pinned Swift revisions for known advisories\n' "$pin_count"
