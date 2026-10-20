#!/bin/sh
# shellcheck disable=SC3043  # `local` is supported by every sh we target
# Helpers for a repo's own checks in .githooks/<hook>.d/. Copied from the dotf
# template (templates/githooks) so the repo needs nothing outside itself.
# The hook runner (lib/run-local.sh) exports HOOK_HELPERS with this path and,
# where relevant, PROJECT_HOOK_INDEX_FILE (pre-commit) and HOOK_STDIN_FILE
# (pre-push). Source it from a .d script:
#   . "${HOOK_HELPERS:?run from .githooks (scripts/setup-hooks)}"
# The generic commit-msg and pre-push checks source it too, so the trailer
# rule they share lives in one place and the two hooks cannot disagree.
# POSIX sh plus `local`, so it works with bash 3.2, dash, zsh and macOS sh.

# The owner alone certifies the DCO for every repo that carries these hooks,
# so the only trailer a commit may hold is the owner's own sign-off. Any
# other trailer (a co-author, a tool session, a tracker ID, a review policy)
# puts attribution or private references into history that a push makes
# permanent. Test scripts read these to commit as the owner.
OWNER_NAME='Sercan Sagman'
OWNER_EMAIL='ahmetsercansagman@gmail.com'
OWNER_SIGNOFF="Signed-off-by: $OWNER_NAME <$OWNER_EMAIL>"

# Hosting sites credit a co-author from such a line even when git's parser
# does not see it as a trailer (for example in a middle paragraph), so the
# owner bans it anywhere in the message, in any letter case. Anchored at the
# line start: comment lines and every `commit -v` diff line start with
# another character, so neither can match.
CO_AUTHOR_LINE_RE='^co-authored-by:'

# Run git against the index being committed. `commit -a`, `commit <paths>`
# and `--only` use a temporary index, so this follows the one git chose.
#   staged_git diff --cached --check
staged_git() {
	: "${PROJECT_HOOK_INDEX_FILE:?staged_git: pre-commit only}"
	GIT_INDEX_FILE=$PROJECT_HOOK_INDEX_FILE git "$@"
}

# pre-push: print the local SHAs being pushed (deletions skipped), one per
# line, from git's ref lines. Use a for loop, never `pushed_shas | while`:
# a failure inside a piped loop only ends the subshell, so the push passes.
#   shas=$(pushed_shas <"$HOOK_STDIN_FILE") || exit 1
#   for sha in $shas; do at_sha "$sha" make test || exit 1; done
pushed_shas() {
	local z40 _lr local_sha _rr _rs
	z40=0000000000000000000000000000000000000000
	while read -r _lr local_sha _rr _rs; do
		[ -n "$local_sha" ] || continue
		case "$local_sha" in
		*[!0-9a-f]*) echo "pushed_shas: malformed ref line" >&2; return 1 ;;
		esac
		[ "$local_sha" = "$z40" ] && continue
		printf '%s\n' "$local_sha"
	done
	return 0
}

# pre-push: run a command against exactly the pushed commit, so a push of
# several commits or of a branch that is not checked out tests what leaves
# the machine. In place when the commit is a clean HEAD; otherwise in a
# temporary detached worktree that is removed afterwards.
at_sha() {
	local sha tmp rc
	sha=$1
	shift
	git rev-parse --verify -q "$sha^{commit}" >/dev/null || { echo "at_sha: unknown commit $sha" >&2; return 1; }
	if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$sha^{commit}")" ] &&
		git diff --quiet HEAD -- && [ -z "$(git ls-files --others --exclude-standard)" ]; then
		"$@"
		return
	fi
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/hook-at-sha.XXXXXX") || return 1
	git worktree add -q --detach "$tmp/wt" "$sha" || { rmdir "$tmp"; return 1; }
	rc=0
	# git's per-repo variables would point the command back at this worktree.
	(cd "$tmp/wt" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && "$@") || rc=$?
	git worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
	# Only the mktemp directory this call created, never a computed parent.
	case "$tmp" in
	*/hook-at-sha.*) rm -rf -- "$tmp" ;;
	esac
	return "$rc"
}

# commit-msg and pre-push: read a commit message on stdin and print one
# reason per line for each break of the owner-only trailer rule; return 1 if
# there is one. git's own parser finds the trailers, so the hook judges the
# same block that `git commit -s` extends and `git log --format=%(trailers)`
# shows, including folded lines and comment or scissors lines left by the
# editor. --no-divider because a "---" line only ends a format-patch mail; in
# a commit message it must not hide the trailers after it. Co-author lines
# outside the trailer block fail too (see CO_AUTHOR_LINE_RE).
#   reasons=$(trailer_violations <"$msg_file") || reject "$reasons"
trailer_violations() {
	local message trailers co_authors line owner_count rc
	# stdin can be read only once, and both checks below need the message.
	message=$(cat)
	if ! trailers=$(printf '%s\n' "$message" | git interpret-trailers --parse --no-divider); then
		echo "cannot read the trailers (git interpret-trailers failed)"
		return 1
	fi
	owner_count=0
	rc=0
	# A here-document, not a pipe, so the counts survive the loop.
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ "$line" = "$OWNER_SIGNOFF" ]; then
			owner_count=$((owner_count + 1))
		else
			echo "trailer not allowed, only '$OWNER_SIGNOFF' is: $line"
			rc=1
		fi
	done <<EOF
$trailers
EOF
	co_authors=$(printf '%s\n' "$message" | grep -iE "$CO_AUTHOR_LINE_RE" || true)
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		# A co-author line inside the trailer block is already reported above.
		if printf '%s\n' "$trailers" | grep -qxF -- "$line"; then
			continue
		fi
		echo "co-author line not allowed anywhere in the message: $line"
		rc=1
	done <<EOF
$co_authors
EOF
	if [ "$owner_count" -eq 0 ]; then
		echo "missing '$OWNER_SIGNOFF': run scripts/setup-hooks, or commit with -s as the owner"
		rc=1
	elif [ "$owner_count" -gt 1 ]; then
		echo "duplicate '$OWNER_SIGNOFF' lines: keep exactly one"
		rc=1
	fi
	return "$rc"
}

# Steps that need the macOS SDK print a skip notice elsewhere instead of
# blocking commits on Linux machines.
darwin_only() {
	if [ "$(uname -s)" != Darwin ]; then
		echo "skip (macOS only): $*" >&2
		return 0
	fi
	"$@"
}
