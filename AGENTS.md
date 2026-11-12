# AGENTS.md

AppleBox: a macOS launcher (app search and clipboard history) in Swift. See
`README.md` and `docs/TESTING.md`.

## Git hooks

After cloning, run `scripts/setup-hooks` once. It sets
`core.hooksPath=.githooks` for this clone and its worktrees. The hooks run the
generic checks first (DCO sign-off, message structure, gitleaks secret scan,
signed commits on push), then this repo's checks in `.githooks/<hook>.d/`. They
replace pull-request CI.

All checks must pass before a push. Never bypass them with `--no-verify`. The
generic files in `.githooks/` and `scripts/setup-hooks` are copies of the dotf
template (`templates/githooks/`); change them there, not here.

- `pre-commit`: `make format-check`, `make lint`
- `pre-push` runs format and lint, audits the Swift dependency revisions, scans
  Swift code and bundle config with the rules in `.semgrep-swift.yml`
  (`make swift-sast`), blocks duplicated production Swift
  (`make duplication`), builds, and runs the test suite and search benchmark
  once on each pushed tip. A push is one commit or a group of commits with
  one goal; the generic signature, sign-off, message and secret checks still
  run on every pushed commit. The suite includes the app search and clipboard
  smoke flows.
- Both repo checks need macOS. On another host they fail with a clear reason;
  they do not skip.
- `make format` and `make format-check` need the exact SwiftFormat release in
  `SWIFTFORMAT_VERSION` (Makefile). To move to a new release, change that value
  and `--minversion` in `.swiftformat`, run `make format`, and commit all of it
  together.
- `make lint` needs the exact SwiftLint release in `SWIFTLINT_VERSION`
  (Makefile). To move to a new release, change that value and
  `swiftlint_version` in `.swiftlint.yml`, fix the new findings, and commit all
  of it together.

Commit messages follow `.githooks/GIT_CONVENTION.md`, which `commit-msg` and
`pre-push` enforce. The generic checks need gitleaks, osv-scanner, semgrep,
lizard and markdownlint-cli2, plus actionlint and zizmor when a push changes
workflow files. A missing tool blocks the hook.
The Swift checks also need `jq`, `curl`, and `timeout`.
