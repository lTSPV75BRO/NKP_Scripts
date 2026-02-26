# Testing the NKP Dependency Installer

This document describes how to test `install-nkp-deps.sh` across the supported operating systems.

## Supported platforms (test matrix)

| OS        | Distro / variant | Architectures | Package manager |
|-----------|------------------|---------------|-----------------|
| Linux     | Ubuntu           | amd64, arm64  | apt             |
| Linux     | Debian           | amd64, arm64  | apt             |
| Linux     | RHEL / Rocky / Alma | amd64, arm64 | dnf/yum         |
| Linux     | Fedora           | amd64, arm64  | dnf             |
| macOS     | Intel            | amd64         | Homebrew        |
| macOS     | Apple Silicon    | arm64         | Homebrew        |

## Quick checks (no install)

These work on any system with `bash` and `curl`:

```bash
# 1. Show help (validates script runs and option parsing)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --help

# 2. Dry-run (validates OS detection and install path logic; no installs)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --dry-run --skip-nkp

# 3. Verify only (reports versions of already-installed tools)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --verify-only

# 4. Uninstall help (validates uninstall option parsing)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --uninstall --help
```

## Testing per OS

### Linux (Ubuntu / Debian)

- **Option A – Native / VM**  
  Use an Ubuntu or Debian VM (e.g. Multipass, UTM, VirtualBox, or cloud). Then:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --dry-run --skip-nkp
  # Full install (requires sudo and NKP URL when prompted, or use --nkp-url)
  curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --nkp-url "YOUR_NKP_URL"
  ```

- **Option B – Docker (Ubuntu/Debian image)**  
  Script is not meant to run inside Docker (it installs Docker on the host). Use only for quick syntax/help checks:

  ```bash
  docker run --rm -it ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --help"
  ```

### Linux (RHEL / Rocky / Alma / Fedora)

Use a VM or cloud instance with the desired distro, then run the same `curl | bash -s --` commands as above. Ensure `curl` and (for RHEL/Rocky) `ca-certificates` are installed.

### macOS (Intel and Apple Silicon)

- **Intel (amd64):** Use an x86_64 Mac or an x86_64 VM/emulator. Install [Homebrew](https://brew.sh) if needed, then run the same `curl | bash -s --` commands.
- **Apple Silicon (arm64):** Run on an M1/M2/M3 Mac. The script will set `INSTALL_BIN_DIR=/opt/homebrew/bin` when that directory exists.

```bash
# Dry-run (no sudo, no installs)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --dry-run --skip-nkp
```

## CI (GitHub Actions)

The repository includes a workflow that runs on every push/PR:

- **`test.yml`**  
  - Runs the script with `--help` and `--dry-run --skip-nkp` on **Ubuntu** and **macOS** (latest runners).  
  - Optionally runs the same in a **Debian** or **Fedora** container for basic “does it run?” checks.

This does **not** perform full installs (no Docker/kubectl/Helm/NKP install). It only checks that the script runs, option parsing works, and OS detection is correct.

## Manual test checklist

Use this when doing a full manual test pass:

- [ ] **Ubuntu (amd64)** – `--dry-run`, then full install (with NKP URL), then `--verify-only`, then `--uninstall --all`.
- [ ] **Debian (amd64)** – Same as Ubuntu (Docker repo uses DEB822 .sources).
- [ ] **Fedora or RHEL/Rocky (amd64)** – `--dry-run`, then full install (with NKP URL), then verify, then uninstall.
- [ ] **macOS (arm64)** – `--dry-run`, full install (with NKP URL), verify, uninstall; confirm `brew doctor` is clean if using `/opt/homebrew/bin`.
- [ ] **macOS (amd64)** – Same as arm64 if you have an Intel Mac.
- [ ] **Run from pipe** – `curl ... | bash -s -- --help` and `curl ... | bash -s -- --dry-run` (no “unbound variable” or similar errors).
- [ ] **Uninstall** – After install, `--uninstall --all` removes only what the script installed; tools installed elsewhere (e.g. `/usr/bin/nkp`) are reported and not removed.

## Reporting issues

When reporting a failure, include:

- OS and version (e.g. `Ubuntu 24.04`, `macOS 14.x`, `Rocky 9`).
- Architecture: `uname -m` (e.g. `x86_64`, `aarch64`).
- Exact command run (e.g. `curl ... | bash -s -- --dry-run`).
- Full script output and, if relevant, the log file path printed at the end.
