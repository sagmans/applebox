# Contributing to AppleBox

Thank you for your interest. This guide tells you how to report a problem,
how to build AppleBox, and the rules for project collaborators.

## How to contribute

AppleBox accepts issues from everyone. Only project collaborators can push
and open pull requests. The repository blocks pull requests from other
accounts.

- For a bug, open a bug report issue. Give the macOS version, the AppleBox
  version, and the steps that cause the bug.
- For a new feature, open a feature request. Tell what you want to do and
  why.
- For a security problem, do not open an issue. Follow
  [SECURITY.md](SECURITY.md).

You can fork AppleBox and change it under the [MIT License](LICENSE).

## Build

You need macOS 26 or later and Swift 6.2 or later.

```bash
make build
make test
```

To run AppleBox from a local build, see **Local Install** in
[README.md](README.md).

## Rules for collaborators

### Hooks

This project has no hosted CI. The Git hooks in `.githooks/` are the only
gate. Install them once in each clone with `make hooks`. Do not bypass them
with `--no-verify`.

The hooks check secrets, format, lint, commit messages, sign-off, and
signatures. Before a push, they also run the dependency audit, static
analysis, duplication and complexity checks, build, tests, and search
benchmark. A missing tool stops the hook.
[AGENTS.md](AGENTS.md) lists each check and the tools that it needs.

### Commits

Commit messages follow the rules in
[.githooks/GIT_CONVENTION.md](.githooks/GIT_CONVENTION.md). In short:

- Use a Conventional Commits subject, for example `fix(clipboard): keep
  image clips after restart`.
- Write a body that tells why the change exists.
- Sign off each commit to accept the
  [Developer Certificate of Origin](https://developercertificate.org/), and
  sign it with a GPG or SSH key:

  ```bash
  git commit -s -S
  ```

  With an SSH key, also set `gpg.ssh.allowedSignersFile`. The `pre-push`
  hook verifies each signature and fails without it.

Make each commit one change. Each commit must build and pass the tests.
Rebase on the latest `main` before you push.
