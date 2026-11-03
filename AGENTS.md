# AGENTS.md

AppleBox: a macOS launcher (app search and clipboard history) in Swift. See `README.md` and `docs/TESTING.md`.

## Git hooks

After cloning, run `scripts/setup-hooks` once. It sets `core.hooksPath=.githooks` for this clone and its worktrees. The hooks run the generic checks first (DCO sign-off, message structure, gitleaks secret scan, signed commits on push), then this repo's checks in `.githooks/<hook>.d/`. They replace pull-request CI.

All checks must pass before a push. Never bypass them with `--no-verify`. The generic files in `.githooks/` and `scripts/setup-hooks` are copies of the dotf template (`templates/githooks/`); change them there, not here.

- `pre-commit`: `make format-check`, `make lint`
- `pre-push`: `swift build`, `swift test` on each pushed commit
- Both repo checks need macOS. On another host they fail with a clear reason; they do not skip.
- `make format` and `make format-check` need the exact SwiftFormat release in `SWIFTFORMAT_VERSION` (Makefile). To move to a new release, change that value and `--minversion` in `.swiftformat`, run `make format`, and commit all of it together.
