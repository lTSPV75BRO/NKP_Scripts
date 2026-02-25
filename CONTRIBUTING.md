# Contributing to NKP Scripts

Thank you for your interest in contributing. This document explains how to report issues, suggest changes, and submit contributions.

## How to contribute

- **Report bugs** — Open an issue describing the problem, your OS/distro, and steps to reproduce.
- **Suggest improvements** — Open an issue with the feature or change you have in mind.
- **Submit code** — Open a pull request (see below).

## Reporting issues

When opening an issue, please include:

- **What happened** — Clear description of the bug or unexpected behavior.
- **What you expected** — Intended outcome.
- **Environment** — OS (e.g. macOS 14, Ubuntu 22.04), architecture (amd64/arm64), and how you ran the script (options used).
- **Relevant output** — Script output or error messages (redact any sensitive data).

## Pull requests

1. **Fork** the repository and create a branch from `main` (e.g. `fix/issue-description` or `feature/something`).
2. **Make your changes** — Keep commits focused and messages clear.
3. **Test** — Run the script on at least one supported OS (Linux or macOS) if you changed behavior.
4. **Open a PR** — Target the `main` branch and describe what changed and why.

### Code style

- **Shell:** Scripts are Bash (`#!/usr/bin/env bash`). Use `set -euo pipefail` where appropriate.
- **Formatting:** Indent with 2 spaces. Quote variables when used in commands.
- **Compatibility:** Avoid bash-only features that break on older Bash; the script aims to run on common Linux and macOS environments.
- **Logging:** Use the existing `log_info` / `log_warn` / `log_error` helpers for user-facing messages.

### What we’re especially interested in

- Fixes and improvements for **additional Linux distros** or **macOS**.
- **NKP version handling** (new tarball names, version parsing).
- **Documentation** (README, comments, CONTRIBUTING) and **accessibility** of the script (errors, prompts).

## License

By contributing, you agree that your contributions will be licensed under the same [MIT License](LICENSE) that covers this project.
