# Nutanix NKP Dependency Installer / Uninstaller

Production-ready, cross-platform script to install and uninstall dependencies for **Nutanix Kubernetes Provisioning (NKP)** on Linux and macOS. One script handles both install and uninstall (with `--uninstall`).

**Quick start (run from GitHub):**

```bash
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash
```

## What it installs


| Component   | Purpose                                 |
| ----------- | --------------------------------------- |
| **Docker**  | Container runtime for NKP               |
| **kubectl** | Kubernetes CLI (stable release)         |
| **Helm**    | Kubernetes package manager              |
| **NKP CLI** | Nutanix NKP tool (from URL you provide) |


After installation, the script verifies each component and reports versions. Optional minimum-version checks can warn if versions are below recommended levels.

## Supported platforms

- **Linux**: Debian/Ubuntu (apt), RHEL/CentOS/Rocky/Alma (dnf/yum), Fedora — Docker from official distro repos; other distros use the [get.docker.com](https://get.docker.com) script
- **macOS**: Intel (amd64) and Apple Silicon (arm64); Docker via **Homebrew** (`brew install --cask docker`); Helm via Homebrew when available, else [get-helm-4](https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4); kubectl via direct download
- **Architectures**: amd64 (x86_64), arm64 (aarch64)

## Requirements

- **Linux**: `sudo` and one of apt, dnf, or yum. The script installs curl, wget, tar, git (and ca-certificates). If the package manager fails (e.g. "No URLs in mirrorlist"), fix repos or install these tools manually. Docker install must succeed or the script exits.
- **macOS**: [Homebrew](https://brew.sh) (for Docker); curl is built-in

### Fixing "No URLs in mirrorlist" (Rocky / RHEL / Alma)

If the installer fails with **No URLs in mirrorlist** (baseos/appstream unreachable), fix the repo files then re-run:

```bash
# Backup repo directory
sudo cp -r /etc/yum.repos.d /etc/yum.repos.d.bak

# Rocky Linux: comment mirrorlist and use baseurl (use lowercase rocky*.repo)
sudo sed -i 's/^mirrorlist/#mirrorlist/g' /etc/yum.repos.d/rocky*.repo
sudo sed -i 's/^#baseurl/baseurl/g' /etc/yum.repos.d/rocky*.repo

# Refresh cache
sudo dnf clean all && sudo dnf makecache
```

Then run the installer again.

## Usage

### Run directly from GitHub

You can run the installer without cloning the repo:

```bash
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash
```

To pass options to the script, use `**bash -s --**` (note the space and double dash), then the script options:

```bash
# Show help (must use "bash -s -- --help", not "bash -s --help")
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --help

# Install, skip Docker, dry-run
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --skip-docker --dry-run

# Install with NKP URL (non-interactive)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --nkp-url "https://download.nutanix.com/..."

# Uninstall (prompts for which components)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --uninstall

# Verify only (no install)
curl -fsSL https://raw.githubusercontent.com/lTSPV75BRO/NKP_Scripts/main/install-nkp-deps.sh | bash -s -- --verify-only
```

> **Note:** Piping from the internet runs the script in your environment. Use only from trusted sources. Prefer downloading and inspecting the script when in doubt.

### Run from a local clone

```bash
# Make executable (once)
chmod +x install-nkp-deps.sh

# Full install (will prompt for NKP URL)
./install-nkp-deps.sh

# Non-interactive: provide NKP URL
./install-nkp-deps.sh --nkp-url "https://portal.nutanix.com/..."

# Skip components you already have
./install-nkp-deps.sh --skip-docker --skip-kubectl

# Only verify already-installed tools
./install-nkp-deps.sh --verify-only

# Preview what would run (no changes)
./install-nkp-deps.sh --dry-run
```

### Uninstall (same script, `--uninstall`)

Uninstall is built into the same script. Use `--uninstall`; with no component flags, it prompts which to remove.

```bash
# Interactive: choose which components to uninstall (d/k/h/n or names, or 'all'/'none')
./install-nkp-deps.sh --uninstall

# Uninstall specific components (no prompt)
./install-nkp-deps.sh --uninstall --kubectl --nkp
./install-nkp-deps.sh --uninstall --all
```

Uninstall also removes the NKP Scripts completion/alias block from `~/.bashrc`/`~/.zshrc` and reminds you to run `hash -r` (bash) or `rehash` (zsh) so uninstalled commands are no longer looked up from cache.

You can also run `./uninstall-nkp-deps.sh` (wrapper that calls `install-nkp-deps.sh --uninstall`).


| Option (with `--uninstall`) | Component                                     |
| --------------------------- | --------------------------------------------- |
| `--docker`                  | Docker (package/cask removal on Linux/macOS)  |
| `--kubectl`                 | kubectl binary (from install script location) |
| `--helm`                    | Helm binary                                   |
| `--nkp`                     | NKP CLI binary                                |
| `--all`                     | All four components                           |


### Install script options


| Option            | Description                                     |
| ----------------- | ----------------------------------------------- |
| `--skip-docker`   | Do not install or start Docker                  |
| `--skip-kubectl`  | Do not install kubectl                          |
| `--skip-helm`     | Do not install Helm                             |
| `--skip-nkp`      | Do not install NKP CLI                          |
| `--nkp-url URL`   | NKP download URL (avoids prompt)                |
| `--dry-run`       | Log actions only; do not install                |
| `--verify-only`   | Only run version checks; do not install         |
| `--log-file PATH` | Log file path (default: `install-nkp-deps.log`) |
| `-h`, `--help`    | Show help                                       |


## NKP URL and file naming

Obtain the NKP CLI download URL from the Nutanix support portal or your Nutanix representative. Expected tarball names:


| Platform              | Example filename                  |
| --------------------- | --------------------------------- |
| Linux (amd64)         | `nkp_v2.17.0_linux_amd64.tar.gz`  |
| Linux (arm64)         | `nkp_v2.17.0_linux_arm64.tar.gz`  |
| macOS (Intel)         | `nkp_v2.17.0_darwin_amd64.tar.gz` |
| macOS (Apple Silicon) | `nkp_v2.17.0_darwin_arm64.tar.gz` |


The script supports:

- **Tarball** (`.tar.gz`): extracts and installs the `nkp` binary from inside (e.g. `nkp_v2.17.0_linux_amd64/nkp`)
- **Direct binary**: installed as `nkp` in `/usr/local/bin`

## Version verification

After install, the script prints:

- **Docker** – server version (or client if no daemon)
- **kubectl** – client version
- **Helm** – version
- **NKP** – output of `nkp version` or “installed”

If any requested component is missing from `PATH`, the script exits with a non-zero status. Optional minimum versions (Docker ≥ 20.10, kubectl ≥ 1.24, Helm ≥ 3.10) are checked and a warning is printed if below.

## Logging

All operations are logged to stderr and to a log file. The default log file is in the system temp directory (`$TMPDIR` on macOS, `/tmp` on Linux) as `install-nkp-deps.<pid>.log`. Override with `--log-file PATH`.

## Post-install

- **Shell completions and alias:** The script adds a small block to your `~/.bashrc` or `~/.zshrc` only for tools that don’t already have completion in the file (idempotent). If your config already sources e.g. kubectl/helm/docker completion (oh-my-zsh plugins, etc.), those lines are skipped; only missing ones (e.g. NKP) are added. Bash also gets alias `k=kubectl` when kubectl completion is added. Reopen your terminal or run `source ~/.bashrc` / `source ~/.zshrc` to use them.
- **`k` or `kubectl` says "No such file or directory":** Your shell may be using a cached path to an old binary (e.g. one that was in `~/.local/bin`). Run `hash -r` (bash) or `rehash` (zsh), or open a new terminal. New installs add a hash clear so this is less likely.
- **Linux (Docker):** If the script adds your user to the `docker` group, **log out and back in** (or run `newgrp docker`) so you can run `docker` without `sudo`.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) for how to report issues, suggest changes, and submit pull requests.

## Testing

To test the script on different OSes (Ubuntu, Debian, RHEL/Fedora, macOS) and in CI, see [TESTING.md](TESTING.md). It includes a test matrix, quick commands (`--help`, `--dry-run`, `--verify-only`), and a manual checklist.

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for the full text. You may use, modify, and distribute it under those terms.

Nutanix NKP (the CLI and platform installed by this script) is subject to [Nutanix](https://www.nutanix.com) licensing and support terms; this repo only provides the installer/uninstaller scripts.