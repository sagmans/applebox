# Contributing to AppleBox

Thank you for your help. This guide tells you how to set up the project, which
checks your change must pass, and how to send it.

## Before you start

- For a bug, open a bug report issue first. Give the macOS version, the
  AppleBox version, and the steps that cause the bug.
- For a new feature or a large change, open a feature request first. The
  maintainer and you agree on the scope before you write code.
- For a security problem, do not open an issue. Follow
  [SECURITY.md](SECURITY.md).

## Set up

You need macOS 26 or later and Swift 6.2 or later.

1. Fork the repository and clone your fork.
2. Install the hooks once in each clone:

   ```bash
   make hooks
   ```

3. Build and run the tests:

   ```bash
   make build
   make test
   ```

To run AppleBox from a local build, see **Local Install** in
[README.md](README.md).

## Checks

This project has no hosted CI. The Git hooks in `.githooks/` are the only
gate. `make hooks` installs them. Do not bypass them with `--no-verify`.

The hooks check secrets, format, lint, commit messages, sign-off, and
signatures. Before a push, they also run the dependency audit, static
analysis, duplication and complexity checks, build, tests, and search
benchmark. A missing tool stops the hook.
[AGENTS.md](AGENTS.md) lists each check and the tools that it needs.

## Commits

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

## Pull requests

1. Rebase your branch on the latest `main`.
2. Make sure the hooks pass on push.
3. In the pull request, tell what changed, why, and how you tested it. For a
   visible change, add a screenshot.

The maintainer runs the same checks locally before a merge.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
