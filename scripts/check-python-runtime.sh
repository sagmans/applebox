#!/usr/bin/env bash
# Coverage helpers must not select Apple's Python in a minimal shell environment.
set -euo pipefail

MANAGED_SHEBANG='#!/usr/bin/env -S uv run --no-project --python-preference only-managed python'
REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPOSITORY_ROOT"
python_files="$(git ls-files '*.py')"
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  IFS= read -r first_line < "$file"
  if [[ "$first_line" == '#!'* && "$first_line" != "$MANAGED_SHEBANG" ]]; then
    printf 'Python entry point must use the managed runtime: %s\n' "$file" >&2
    exit 1
  fi
done <<< "$python_files"
printf 'Python entry-point policy passed\n'
