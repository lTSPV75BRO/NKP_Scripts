#!/usr/bin/env bash
#
# Nutanix NKP (Nutanix Kubernetes Provisioning) Dependency Installer / Uninstaller
# Production-ready, cross-platform script for Linux and macOS.
#
# Install: Docker, kubectl, Helm, NKP CLI (from URL). Verifies versions after install.
# Uninstall: --uninstall to remove components (prompts which, or use --docker/--kubectl/--helm/--nkp/--all).
#
# Expected NKP tarball naming (from Nutanix portal):
#   Linux:  nkp_v2.17.0_linux_amd64.tar.gz  (or linux_arm64)
#   macOS:  nkp_v2.17.0_darwin_amd64.tar.gz (or darwin_arm64)
#
# Usage: ./install-nkp-deps.sh [OPTIONS]
#   Install mode (default): --skip-docker, --skip-kubectl, --skip-helm, --skip-nkp, --nkp-url, --dry-run, --verify-only, --log-file
#   Uninstall mode: --uninstall [--docker] [--kubectl] [--helm] [--nkp] [--all]  (no flags = prompt for which to uninstall)
#

set -euo pipefail

# --- Configuration ---
# When run via "curl | bash", BASH_SOURCE[0] is unset; use $0 so SCRIPT_DIR is current directory
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOG_FILE="${TMPDIR:-/tmp}/install-nkp-deps.$$.log"
readonly KUBECTL_STABLE_URL="https://dl.k8s.io/release/stable.txt"
readonly KUBECTL_BASE_URL="https://dl.k8s.io/release"
readonly HELM_INSTALL_SCRIPT="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4"

# Minimum versions (optional checks; set empty to skip)
MIN_DOCKER_VERSION="20.10"
MIN_KUBECTL_VERSION="1.24"
MIN_HELM_VERSION="3.10"

# --- State ---
DRY_RUN=false
SKIP_DOCKER=false
SKIP_KUBECTL=false
SKIP_HELM=false
SKIP_NKP=false
NKP_URL=""
VERIFY_ONLY=false
UNINSTALL_MODE=false
UNINSTALL_DOCKER=false
UNINSTALL_KUBECTL=false
UNINSTALL_HELM=false
UNINSTALL_NKP=false
OS_TYPE=""   # linux | darwin
OS_DISTRO="" # debian | rhel | fedora | ubuntu | ...
ARCH=""     # amd64 | arm64
INSTALL_BIN_DIR=""  # set in detect_os: /opt/homebrew/bin (macOS ARM) or /usr/local/bin

# --- Logging ---
log() {
  local level="${1:-INFO}"
  shift
  local msg="$*"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Redact URLs in command args for logging (NKP URLs may contain tokens)
redact_cmd_for_log() {
  local first=1 arg
  for arg in "$@"; do
    [[ "$first" -eq 0 ]] && echo -n " "
    if [[ "$arg" == https://* || "$arg" == http://* ]]; then
      echo -n "<url-redacted>"
    else
      printf '%s' "$arg"
    fi
    first=0
  done
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  log_info "Running: $(redact_cmd_for_log "$@")"
  "$@"
}

# --- OS detection ---
detect_os() {
  local uname_s
  uname_s=$(uname -s)
  case "$uname_s" in
    Linux)
      OS_TYPE=linux
      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
      esac
      if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "${ID:-}" in
          ubuntu|debian) OS_DISTRO=debian ;;
          rhel|centos|rocky|almalinux|ol) OS_DISTRO=rhel ;;
          fedora) OS_DISTRO=fedora ;;
          *)
            if [[ "${ID_LIKE:-}" == *debian* ]]; then OS_DISTRO=debian
            elif [[ "${ID_LIKE:-}" == *rhel* ]] || [[ "${ID_LIKE:-}" == *fedora* ]]; then OS_DISTRO=rhel
            else OS_DISTRO=unknown
            fi
            ;;
        esac
      else
        OS_DISTRO=unknown
      fi
      ;;
    Darwin)
      OS_TYPE=darwin
      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64) ARCH=amd64 ;;
        arm64) ;;
        *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
      esac
      OS_DISTRO=darwin
      ;;
    *)
      log_error "Unsupported OS: $uname_s"
      exit 1
      ;;
  esac
  # Prefer /opt/homebrew/bin on macOS (ARM) so script-installed tools take precedence over Homebrew
  if [[ "$OS_TYPE" == darwin ]] && [[ -d /opt/homebrew/bin ]]; then
    INSTALL_BIN_DIR="/opt/homebrew/bin"
    INSTALL_USE_SUDO=false
  else
    INSTALL_BIN_DIR="/usr/local/bin"
    INSTALL_USE_SUDO=true
  fi
  log_info "Detected: OS_TYPE=$OS_TYPE OS_DISTRO=$OS_DISTRO ARCH=$ARCH INSTALL_BIN_DIR=$INSTALL_BIN_DIR"
}

# Install a binary into INSTALL_BIN_DIR. On macOS /opt/homebrew/bin we do not use sudo
# so ownership stays with the user and brew doctor is not affected.
install_binary_to_bindir() {
  local src="$1"
  local dest_name="$2"
  if [[ "$INSTALL_USE_SUDO" == true ]]; then
    run sudo install -d -o 0 -g 0 -m 0755 "$INSTALL_BIN_DIR" 2>/dev/null || true
    run sudo install -o 0 -g 0 -m 0755 "$src" "$INSTALL_BIN_DIR/$dest_name"
  else
    run mkdir -p "$INSTALL_BIN_DIR"
    run install -m 0755 "$src" "$INSTALL_BIN_DIR/$dest_name"
  fi
}

# --- Version comparison (semver-style) ---
version_gte() {
  # Returns 0 if $1 >= $2 (by comparing first few dot-separated numbers)
  local a b i
  local v1 v2
  v1=$(echo "$1" | tr -d '[:space:]')
  v2=$(echo "$2" | tr -d '[:space:]')
  IFS=. read -ra a <<< "$v1"
  IFS=. read -ra b <<< "$v2"
  for (( i=0; i < ${#b[@]}; i++ )); do
    local ai="${a[i]:-0}"
    local bi="${b[i]:-0}"
    local ai_num bi_num
    ai_num=$((10#${ai//[!0-9]/}))
    bi_num=$((10#${bi//[!0-9]/}))
    if (( ai_num > bi_num )); then return 0; fi
    if (( ai_num < bi_num )); then return 1; fi
  done
  return 0
}

# --- Get installed / latest versions (for pre-install check) ---
get_installed_docker_version() {
  docker version --format '{{.Server.Version}}' 2>/dev/null | head -1 | tr -d '[:space:]' || \
  docker --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1 | tr -d '[:space:]' || echo ""
}

get_latest_docker_version() {
  if [[ "$OS_TYPE" == linux ]]; then
    if command -v apt-get &>/dev/null && apt-cache policy docker-ce 2>/dev/null | grep -q Candidate; then
      apt-cache policy docker-ce 2>/dev/null | sed -n 's/.*Candidate: \([0-9.:~-]*\).*/\1/p' | head -1 | sed 's/-.*//' || echo ""
    elif command -v dnf &>/dev/null; then
      dnf list docker-ce 2>/dev/null | awk '/docker-ce/ {print $2; exit}' | sed 's/-.*//' || echo ""
    fi
  fi
  # macOS: no simple "latest" without scraping; leave empty
}

get_installed_kubectl_version() {
  kubectl version --client -o short 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p;q' || \
  kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || echo ""
}

get_latest_kubectl_version() {
  curl -sL "$KUBECTL_STABLE_URL" 2>/dev/null | sed 's/^v//' || echo ""
}

get_installed_helm_version() {
  helm version --short 2>/dev/null | sed 's/.*v\([0-9.]*\).*/\1/;q' | tr -d '[:space:]' || echo ""
}

get_latest_helm_version() {
  curl -sL https://api.github.com/repos/helm/helm/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/' | head -1 | tr -d '[:space:]' || echo ""
}

get_installed_nkp_version() {
  # nkp version outputs multiple lines (catalog:, diagnose:, nkp:, ...); use the "nkp:" line only
  nkp version 2>/dev/null | grep -E '^[[:space:]]*nkp:' | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || \
  nkp version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || \
  nkp --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || echo ""
}

# Parse NKP version from URL or filename (e.g. nkp_v2.17.0_darwin_amd64.tar.gz -> 2.17.0)
parse_nkp_version_from_url() {
  local u="$1"
  echo "$u" | grep -oE 'nkp_v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/nkp_v//' || echo ""
}

# Log installed vs latest and return 0 to skip install (already at latest), 1 to proceed.
# Usage: check_versions_before_install "kubectl" "$installed" "$latest"
check_versions_before_install() {
  local name="$1"
  local installed="$2"
  local latest="$3"
  installed=$(echo "$installed" | tr -d '[:space:]')
  latest=$(echo "$latest" | tr -d '[:space:]')
  if [[ -n "$installed" ]]; then
    log_info "$name: installed=$installed"
  else
    log_info "$name: not installed"
  fi
  if [[ -n "$latest" ]]; then
    log_info "$name: latest/available=$latest"
  fi
  if [[ -n "$installed" && -n "$latest" ]] && version_gte "$installed" "$latest"; then
    log_info "$name: already at latest, skipping install."
    return 0
  fi
  return 1
}

# --- Install prerequisites (curl, wget, etc.) ---
install_prereqs() {
  if [[ "$OS_TYPE" == darwin ]]; then
    if ! command -v brew &>/dev/null; then
      log_error "Homebrew is required on macOS. Install from https://brew.sh"
      exit 1
    fi
    run brew update || true
    return 0
  fi

  case "$OS_DISTRO" in
    debian)
      run sudo apt-get update -qq
      run sudo apt-get install -y -qq curl wget ca-certificates apt-transport-https gnupg lsb-release
      ;;
    rhel|fedora)
      run sudo dnf install -y curl wget ca-certificates 2>/dev/null || run sudo yum install -y curl wget ca-certificates
      ;;
    *)
      log_warn "Unknown Linux distro; ensure curl and wget are installed."
      ;;
  esac
}

# --- Docker installation ---
# Linux: repo-based install for Debian/Ubuntu and RHEL/Fedora (recommended for production).
#        Unknown distros use the official get.docker.com script.
# macOS: Homebrew (Docker Desktop) or manual download.
readonly DOCKER_GET_SCRIPT_URL="https://get.docker.com"

install_docker_linux() {
  case "$OS_DISTRO" in
    debian)
      run sudo apt-get update -qq
      run sudo apt-get install -y -qq ca-certificates curl
      run sudo install -m 0755 -d /etc/apt/keyrings
      local docker_repo_id suite
      docker_repo_id=$( (. /etc/os-release && echo "$ID") || echo "ubuntu")
      # Remove all Docker keys and sources to avoid Signed-By conflict
      run sudo rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
      run sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker*.list /etc/apt/sources.list.d/*docker* 2>/dev/null || true
      # Add Docker's official GPG key (ASCII armored, as docker.asc)
      run sudo curl -fsSL "https://download.docker.com/linux/${docker_repo_id}/gpg" -o /etc/apt/keyrings/docker.asc
      run sudo chmod a+r /etc/apt/keyrings/docker.asc
      # Add repository using DEB822 format (.sources)
      suite=$( (. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}") || echo "unknown")
      run sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_repo_id}
Suites: ${suite}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      run sudo apt-get update -qq
      run sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io
      ;;
    rhel|fedora)
      run sudo dnf install -y dnf-plugins-core 2>/dev/null || run sudo yum install -y yum-utils
      run sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
        run sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      run sudo dnf install -y docker-ce docker-ce-cli containerd.io 2>/dev/null || \
        run sudo yum install -y docker-ce docker-ce-cli containerd.io
      ;;
    *)
      log_info "Using Docker official install script (get.docker.com) for this distro."
      run bash -c "curl -fsSL $DOCKER_GET_SCRIPT_URL | sudo sh -s --" || {
        log_error "Docker install failed. Install manually: https://docs.docker.com/engine/install/"
        exit 1
      }
      ;;
  esac
  if [[ "$DRY_RUN" != true ]]; then
    if command -v systemctl &>/dev/null; then
      run sudo systemctl start docker 2>/dev/null || true
      run sudo systemctl enable docker 2>/dev/null || true
    fi
    if [[ -n "${SUDO_USER:-}" ]]; then
      run sudo usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    elif [[ -n "${USER:-}" && "$USER" != root ]]; then
      run sudo usermod -aG docker "$USER" 2>/dev/null || true
    fi
  fi
}

install_docker_darwin() {
  if command -v docker &>/dev/null; then
    log_info "Docker already installed."
    return 0
  fi
  if command -v brew &>/dev/null; then
    log_info "Installing Docker Desktop via Homebrew (brew install --cask docker)."
    run brew install --cask docker 2>/dev/null || {
      log_warn "brew install --cask docker failed. Install manually: https://www.docker.com/products/docker-desktop/"
    }
  else
    log_error "Homebrew not found. Install Docker Desktop manually: https://www.docker.com/products/docker-desktop/"
    log_info "Or install Homebrew (https://brew.sh) then run: brew install --cask docker"
  fi
}

install_docker() {
  [[ "$SKIP_DOCKER" == true ]] && return 0
  log_info "Checking Docker version (installed vs available)..."
  set +e
  local inst_latest avail
  inst_latest=$(get_installed_docker_version)
  avail=$(get_latest_docker_version)
  set -e
  if [[ -n "$inst_latest" ]]; then
    log_info "Docker: installed=$inst_latest"
  else
    log_info "Docker: not installed"
  fi
  if [[ -n "$avail" ]]; then
    log_info "Docker: available (repo)=$avail"
    if [[ -n "$inst_latest" ]] && version_gte "$inst_latest" "$avail"; then
      log_info "Docker: already at available version, skipping install."
      return 0
    fi
  fi
  log_info "Installing Docker..."
  if [[ "$OS_TYPE" == darwin ]]; then
    install_docker_darwin
  else
    install_docker_linux
  fi
}

# --- kubectl installation ---
install_kubectl() {
  [[ "$SKIP_KUBECTL" == true ]] && return 0
  log_info "Checking kubectl version (installed vs latest)..."
  set +e
  local inst_latest latest
  inst_latest=$(get_installed_kubectl_version)
  latest=$(get_latest_kubectl_version)
  set -e
  if check_versions_before_install "kubectl" "$inst_latest" "$latest"; then
    return 0
  fi
  log_info "Installing kubectl..."
  local version
  version=$(curl -sL "$KUBECTL_STABLE_URL")
  local url="${KUBECTL_BASE_URL}/${version}/bin/${OS_TYPE}/${ARCH}/kubectl"
  local tmpdir
  tmpdir=$(mktemp -d)
  run curl -sSLo "$tmpdir/kubectl" "$url"
  run chmod +x "$tmpdir/kubectl"
  install_binary_to_bindir "$tmpdir/kubectl" "kubectl"
  rm -rf "$tmpdir"
  log_info "kubectl installed: $version -> $INSTALL_BIN_DIR/kubectl"
}

# --- Helm installation ---
install_helm() {
  [[ "$SKIP_HELM" == true ]] && return 0
  log_info "Checking Helm version (installed vs latest)..."
  set +e
  local inst_latest latest
  inst_latest=$(get_installed_helm_version)
  latest=$(get_latest_helm_version)
  set -e
  if check_versions_before_install "Helm" "$inst_latest" "$latest"; then
    return 0
  fi
  log_info "Installing Helm..."
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: curl get-helm-4 | bash or download binary"
    return 0
  fi
  if ! command -v helm &>/dev/null; then
    # On macOS with /opt/homebrew/bin we install without sudo; get-helm-4 may use sudo, so use binary fallback.
    if [[ "$INSTALL_USE_SUDO" == false ]]; then
      log_info "Installing Helm via binary download (no sudo for $INSTALL_BIN_DIR)."
      local version
      version=$(curl -sL https://api.github.com/repos/helm/helm/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
      [[ -z "$version" ]] && version="3.13.0"
      local url="https://get.helm.sh/helm-v${version}-${OS_TYPE}-${ARCH}.tar.gz"
      local tmpdir
      tmpdir=$(mktemp -d)
      run curl -sSLo "$tmpdir/helm.tar.gz" "$url"
      run tar -xzf "$tmpdir/helm.tar.gz" -C "$tmpdir" "${OS_TYPE}-${ARCH}/helm"
      install_binary_to_bindir "$tmpdir/${OS_TYPE}-${ARCH}/helm" "helm"
      rm -rf "$tmpdir"
    else
      log_info "Installing Helm via get-helm-4 script..."
      run env HELM_INSTALL_DIR="$INSTALL_BIN_DIR" bash -c "curl -fsSL $HELM_INSTALL_SCRIPT | bash" || {
        local version
        version=$(curl -sL https://api.github.com/repos/helm/helm/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
        [[ -z "$version" ]] && version="3.13.0"
        local url="https://get.helm.sh/helm-v${version}-${OS_TYPE}-${ARCH}.tar.gz"
        local tmpdir
        tmpdir=$(mktemp -d)
        run curl -sSLo "$tmpdir/helm.tar.gz" "$url"
        run tar -xzf "$tmpdir/helm.tar.gz" -C "$tmpdir" "${OS_TYPE}-${ARCH}/helm"
        install_binary_to_bindir "$tmpdir/${OS_TYPE}-${ARCH}/helm" "helm"
        rm -rf "$tmpdir"
      }
    fi
  fi
}

# --- NKP CLI installation ---
install_nkp() {
  [[ "$SKIP_NKP" == true ]] && return 0

  local url="$NKP_URL"
  if [[ -z "$url" ]]; then
    if [[ -t 0 ]]; then
      printf "Enter the Nutanix NKP CLI download URL (from Nutanix support portal): "
      read -r url
    else
      log_error "NKP URL not provided. Use --nkp-url URL or run interactively."
      exit 1
    fi
  fi
  url=$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Normalize URL: remove backslash escapes often present when pasting (e.g. \? \& \= \~)
  # Use sed because bash ${var//\\?/?} would make ? match any char (glob) and corrupt & and =
  # Signature often contains ~ which may be pasted as \~
  url=$(echo "$url" | sed 's/\\?/?/g; s/\\&/\&/g; s/\\=/=/g; s/\\~/~/g')
  if [[ -z "$url" ]]; then
    log_error "No NKP URL provided. Exiting."
    exit 1
  fi

  log_info "Checking NKP version (installed vs URL)..."
  set +e
  local inst_ver url_ver
  inst_ver=$(get_installed_nkp_version)
  url_ver=$(parse_nkp_version_from_url "$url")
  set -e
  if [[ -n "$inst_ver" ]]; then
    log_info "NKP: installed=$inst_ver"
  else
    log_info "NKP: not installed"
  fi
  if [[ -n "$url_ver" ]]; then
    log_info "NKP: version from URL=$url_ver"
    if [[ -n "$inst_ver" ]] && [[ "$inst_ver" == "$url_ver" ]]; then
      log_info "NKP: already at requested version, skipping install."
      return 0
    fi
  fi

  # Redact URL in log (query string may contain tokens)
  log_info "Downloading NKP from: $(echo "$url" | sed -e 's/[?].*/?***/')"
  local tmpdir
  tmpdir=$(mktemp -d)

  local filename
  filename=$(basename "$url" | sed 's/[?].*//')
  if [[ -z "$filename" || "$filename" == "$(basename "$url")" ]]; then
    filename="nkp-download"
  fi

  if ! run curl -fsSLo "$tmpdir/$filename" "$url"; then
    log_error "Failed to download NKP from URL."
    exit 1
  fi

  if [[ "$filename" == *.tar.gz ]] || [[ "$filename" == *.tgz ]]; then
    run tar -xzf "$tmpdir/$filename" -C "$tmpdir"
    local nkp_bin
    # Expected layout: nkp_v2.17.0_linux_amd64/nkp or nkp_v2.17.0_darwin_amd64/nkp
    nkp_bin=$(find "$tmpdir" -type f -name 'nkp' 2>/dev/null | head -1)
    if [[ -z "$nkp_bin" ]]; then
      nkp_bin=$(find "$tmpdir" -type f -path "*${OS_TYPE}*" -name 'nkp' 2>/dev/null | head -1)
    fi
    if [[ -z "$nkp_bin" ]]; then
      nkp_bin=$(find "$tmpdir" -type f -executable 2>/dev/null | head -1)
    fi
    if [[ -n "$nkp_bin" ]]; then
      run chmod +x "$nkp_bin"
      install_binary_to_bindir "$nkp_bin" "nkp"
    else
      log_error "Could not find nkp binary in archive (expected e.g. nkp_v2.17.0_${OS_TYPE}_${ARCH}/nkp)."
      exit 1
    fi
  elif file "$tmpdir/$filename" | grep -q executable; then
    run chmod +x "$tmpdir/$filename"
    install_binary_to_bindir "$tmpdir/$filename" "nkp"
  else
    rm -rf "$tmpdir"
    log_error "Unrecognized download format. Expecting tarball or binary."
    exit 1
  fi
  rm -rf "$tmpdir"
  log_info "NKP installed to $INSTALL_BIN_DIR/nkp"
  if [[ -n "${url_ver:-}" ]]; then
    log_info "Download NKP OS version ${url_ver} from https://portal.nutanix.com/page/downloads?product=nkp and import the image to your Prism Central"
  else
    log_info "Download NKP OS (same version as NKP CLI) from https://portal.nutanix.com/page/downloads?product=nkp and import the image to your Prism Central"
  fi
}

# --- Shell completion and alias (k=kubectl) ---
configure_completion() {
  [[ "$DRY_RUN" == true ]] && return 0
  local shell_name shell_rc
  shell_name=$(basename "${SHELL:-bash}")
  case "$shell_name" in
    bash)  shell_rc="${HOME}/.bashrc" ;;
    zsh)   shell_rc="${HOME}/.zshrc" ;;
    *)     shell_rc="" ;;
  esac
  if [[ -z "$shell_rc" || ! -w "$shell_rc" ]]; then return 0; fi

  if grep -q "NKP Scripts - completions and alias" "$shell_rc" 2>/dev/null; then
    log_info "Completions and alias already present in $shell_rc"
    return 0
  fi

  echo "" >> "$shell_rc"
  echo "# --- NKP Scripts - completions and alias (added by install-nkp-deps.sh) ---" >> "$shell_rc"
  # Clear command hash so kubectl/k are resolved from current PATH (avoids stale path to removed binary)
  if [[ "$shell_name" == bash ]]; then
    echo "hash -r 2>/dev/null || true" >> "$shell_rc"
  else
    echo "rehash 2>/dev/null || true" >> "$shell_rc"
  fi

  if [[ "$shell_name" == bash ]]; then
    # kubectl: source completion, alias k, and register completion for k only if __start_kubectl exists (avoids "function not found")
    if command -v kubectl &>/dev/null; then
      echo "if command -v kubectl &>/dev/null; then source <(kubectl completion bash 2>/dev/null) 2>/dev/null; alias k=kubectl; declare -f __start_kubectl &>/dev/null && complete -o default -F __start_kubectl k 2>/dev/null || true; fi" >> "$shell_rc"
    fi
    # helm
    if command -v helm &>/dev/null; then
      echo "if command -v helm &>/dev/null; then source <(helm completion bash 2>/dev/null); fi" >> "$shell_rc"
    fi
    # docker
    if command -v docker &>/dev/null; then
      echo "if command -v docker &>/dev/null; then source <(docker completion bash 2>/dev/null); fi" >> "$shell_rc"
    fi
    # nkp (if completion available)
    if command -v nkp &>/dev/null && nkp completion bash &>/dev/null; then
      echo "if command -v nkp &>/dev/null; then source <(nkp completion bash 2>/dev/null); fi" >> "$shell_rc"
    fi
  else
    # zsh
    if command -v kubectl &>/dev/null; then
      echo "if command -v kubectl &>/dev/null; then source <(kubectl completion zsh 2>/dev/null); fi" >> "$shell_rc"
      echo "alias k=kubectl" >> "$shell_rc"
    fi
    if command -v helm &>/dev/null; then
      echo "if command -v helm &>/dev/null; then source <(helm completion zsh 2>/dev/null); fi" >> "$shell_rc"
    fi
    if command -v docker &>/dev/null; then
      echo "if command -v docker &>/dev/null; then source <(docker completion zsh 2>/dev/null); fi" >> "$shell_rc"
    fi
    if command -v nkp &>/dev/null && nkp completion zsh &>/dev/null; then
      echo "if command -v nkp &>/dev/null; then source <(nkp completion zsh 2>/dev/null); fi" >> "$shell_rc"
    fi
  fi

  echo "# --- end NKP Scripts ---" >> "$shell_rc"
  log_info "Shell completion and alias k=kubectl configured in $shell_rc (reopen shell or source the file to use)"
}

# --- Version verification ---
# Run with set -e disabled so a failing version command doesn't exit the script.
verify_versions() {
  log_info "Verifying installed versions..."
  local failed=0
  set +e

  if [[ "$SKIP_DOCKER" != true ]]; then
    if command -v docker &>/dev/null; then
      local v
      v=$(docker version --format '{{.Server.Version}}' 2>/dev/null | head -1 | tr -d '\n' || docker --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1) || true
      v=$(echo "$v" | tr -d '[:space:]')
      log_info "Docker: ${v:-unknown}"
      if [[ -n "$MIN_DOCKER_VERSION" && -n "$v" ]] && ! version_gte "${v}" "$MIN_DOCKER_VERSION"; then
        log_warn "Docker version $v is below minimum $MIN_DOCKER_VERSION"
      fi
    else
      log_error "Docker not found in PATH."
      failed=$((failed + 1))
    fi
  fi

  if [[ "$SKIP_KUBECTL" != true ]]; then
    if command -v kubectl &>/dev/null; then
      local v
      v=$(kubectl version --client -o short 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p;q') || true
      if [[ -z "$v" ]]; then
        v=$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v') || true
      fi
      v=$(echo "$v" | tr -d '[:space:]')
      log_info "kubectl: ${v:-unknown}"
      if [[ -n "$MIN_KUBECTL_VERSION" && -n "$v" ]] && ! version_gte "${v}" "$MIN_KUBECTL_VERSION"; then
        log_warn "kubectl version $v is below minimum $MIN_KUBECTL_VERSION"
      fi
    else
      log_error "kubectl not found in PATH."
      failed=$((failed + 1))
    fi
  fi

  if [[ "$SKIP_HELM" != true ]]; then
    if command -v helm &>/dev/null; then
      local v
      v=$(helm version --short 2>/dev/null | sed 's/.*v\([0-9.]*\).*/\1/;q') || true
      v=$(echo "$v" | tr -d '[:space:]')
      log_info "Helm: ${v:-unknown}"
      if [[ -n "$MIN_HELM_VERSION" && -n "$v" ]] && ! version_gte "${v}" "$MIN_HELM_VERSION"; then
        log_warn "Helm version $v is below minimum $MIN_HELM_VERSION"
      fi
    else
      log_error "Helm not found in PATH."
      failed=$((failed + 1))
    fi
  fi

  if [[ "$SKIP_NKP" != true ]]; then
    if command -v nkp &>/dev/null; then
      local v
      v=$(nkp version 2>/dev/null || nkp --version 2>/dev/null || echo "installed") || true
      log_info "NKP: $v"
    else
      log_error "nkp not found in PATH."
      failed=$((failed + 1))
    fi
  fi

  set -e
  if [[ $failed -gt 0 ]]; then
    log_error "Version check failed for $failed component(s)."
    return 1
  fi
  log_info "All requested components verified."
  return 0
}

# --- Uninstall: prompt for which components ---
prompt_uninstall_components() {
  echo ""
  echo "Which components do you want to uninstall?"
  echo "  Enter one or more letters (e.g. k,h,n or docker,kubectl,helm,nkp), or 'all' / 'none':"
  echo "    d = Docker"
  echo "    k = kubectl"
  echo "    h = Helm"
  echo "    n = NKP CLI"
  echo ""
  printf "Your choice: "
  read -r choice
  choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

  UNINSTALL_DOCKER=false
  UNINSTALL_KUBECTL=false
  UNINSTALL_HELM=false
  UNINSTALL_NKP=false

  if [[ "$choice" == "none" || -z "$choice" ]]; then
    log_info "No components selected. Exiting."
    exit 0
  fi

  if [[ "$choice" == "all" ]]; then
    UNINSTALL_DOCKER=true
    UNINSTALL_KUBECTL=true
    UNINSTALL_HELM=true
    UNINSTALL_NKP=true
    return
  fi

  local i
  for (( i=0; i < ${#choice}; i++ )); do
    case "${choice:$i:1}" in
      d) UNINSTALL_DOCKER=true ;;
      k) UNINSTALL_KUBECTL=true ;;
      h) UNINSTALL_HELM=true ;;
      n) UNINSTALL_NKP=true ;;
      ,) ;;
      *) log_warn "Unknown option ignored: ${choice:$i:1}" ;;
    esac
  done

  if [[ "$choice" == *docker* ]]; then UNINSTALL_DOCKER=true; fi
  if [[ "$choice" == *kubectl* ]]; then UNINSTALL_KUBECTL=true; fi
  if [[ "$choice" == *helm* ]]; then UNINSTALL_HELM=true; fi
  if [[ "$choice" == *nkp* ]]; then UNINSTALL_NKP=true; fi
}

do_uninstall_docker() {
  [[ "$UNINSTALL_DOCKER" != true ]] && return 0
  log_info "Uninstalling Docker..."
  if [[ "$OS_TYPE" == darwin ]]; then
    if command -v brew &>/dev/null && brew list --cask docker &>/dev/null; then
      run brew uninstall --cask docker 2>/dev/null || log_warn "Docker cask uninstall failed or was cancelled."
    else
      log_info "Docker was not installed via Homebrew by this script. Remove Docker Desktop manually if desired."
    fi
  else
    case "$OS_DISTRO" in
      debian)
        run sudo apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        ;;
      rhel|fedora)
        run sudo dnf remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || \
        run sudo yum remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        ;;
      *)
        log_warn "Uninstall Docker manually for this distro."
        ;;
    esac
    # Docker from packages usually lives in /usr/bin; if still in PATH, may be from another install
    if command -v docker &>/dev/null; then
      log_info "Docker is still available at $(command -v docker); remove that binary or re-run package remove if needed."
    fi
  fi
  log_info "Docker uninstall completed."
}

do_uninstall_kubectl() {
  [[ "$UNINSTALL_KUBECTL" != true ]] && return 0
  log_info "Uninstalling kubectl..."
  if [[ -f "$INSTALL_BIN_DIR/kubectl" ]]; then
    [[ "$INSTALL_USE_SUDO" == true ]] && run sudo rm -f "$INSTALL_BIN_DIR/kubectl" || run rm -f "$INSTALL_BIN_DIR/kubectl"
    log_info "Removed $INSTALL_BIN_DIR/kubectl"
  else
    if command -v kubectl &>/dev/null; then
      log_info "kubectl not at $INSTALL_BIN_DIR (found at $(command -v kubectl)); remove manually if desired."
    else
      log_info "kubectl not found at $INSTALL_BIN_DIR/kubectl (may be from another install)."
    fi
  fi
}

do_uninstall_helm() {
  [[ "$UNINSTALL_HELM" != true ]] && return 0
  log_info "Uninstalling Helm..."
  if [[ -f "$INSTALL_BIN_DIR/helm" ]]; then
    [[ "$INSTALL_USE_SUDO" == true ]] && run sudo rm -f "$INSTALL_BIN_DIR/helm" || run rm -f "$INSTALL_BIN_DIR/helm"
    log_info "Removed $INSTALL_BIN_DIR/helm"
  else
    if command -v helm &>/dev/null; then
      log_info "Helm not at $INSTALL_BIN_DIR (found at $(command -v helm)); remove manually if desired."
    else
      log_info "Helm not found at $INSTALL_BIN_DIR/helm (may be from another install)."
    fi
  fi
}

do_uninstall_nkp() {
  [[ "$UNINSTALL_NKP" != true ]] && return 0
  log_info "Uninstalling NKP CLI..."
  # Always run "nkp delete bootstrap" before removing the binary (e.g. cleans up bootstrap cluster).
  # Failures (e.g. no cluster, docker not running) are ignored so uninstall can continue.
  if command -v nkp &>/dev/null; then
    log_info "Running: nkp delete bootstrap (failures are ignored)"
    nkp delete bootstrap 2>/dev/null || true
  fi
  if [[ -f "$INSTALL_BIN_DIR/nkp" ]]; then
    [[ "$INSTALL_USE_SUDO" == true ]] && run sudo rm -f "$INSTALL_BIN_DIR/nkp" || run rm -f "$INSTALL_BIN_DIR/nkp"
    log_info "Removed $INSTALL_BIN_DIR/nkp"
  else
    if command -v nkp &>/dev/null; then
      log_info "NKP not at $INSTALL_BIN_DIR (found at $(command -v nkp)); remove manually if desired."
    else
      log_info "NKP not found at $INSTALL_BIN_DIR/nkp (may be from another install)."
    fi
  fi
}

# Remove the NKP Scripts completion/alias block from shell rc so uninstalled commands are not referenced.
remove_completion_block() {
  local shell_name shell_rc
  shell_name=$(basename "${SHELL:-bash}")
  case "$shell_name" in
    bash)  shell_rc="${HOME}/.bashrc" ;;
    zsh)   shell_rc="${HOME}/.zshrc" ;;
    *)     return 0 ;;
  esac
  [[ -z "$shell_rc" || ! -w "$shell_rc" ]] && return 0
  if ! grep -q "NKP Scripts - completions and alias" "$shell_rc" 2>/dev/null; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  # Remove lines from start marker through end marker (inclusive)
  if sed '/# --- NKP Scripts - completions and alias/,/# --- end NKP Scripts ---/d' "$shell_rc" > "$tmp" && mv "$tmp" "$shell_rc"; then
    log_info "Removed NKP Scripts completion/alias block from $shell_rc"
  else
    rm -f "$tmp" 2>/dev/null || true
    log_warn "Could not update $shell_rc (remove NKP Scripts block manually if needed)."
  fi
}

# --- Usage ---
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Install or uninstall dependencies for Nutanix NKP (Nutanix Kubernetes Provisioning) on Linux or macOS.

INSTALL (default):
  Installs Docker, kubectl, Helm, and NKP CLI (from URL). Verifies versions after install.

  Options:
  --skip-docker     Do not install Docker
  --skip-kubectl    Do not install kubectl
  --skip-helm       Do not install Helm
  --skip-nkp        Do not install NKP CLI
  --nkp-url URL     NKP download URL (avoids prompt)
  --dry-run         Show actions only, do not install
  --verify-only     Only verify installed tool versions (no install)
  --log-file PATH   Log file (default: $LOG_FILE)

UNINSTALL (--uninstall):
  Removes selected components. With no component flags, prompts for which to uninstall.

  Options:
  --uninstall       Switch to uninstall mode
  --docker          Uninstall Docker
  --kubectl         Uninstall kubectl
  --helm            Uninstall Helm
  --nkp             Uninstall NKP CLI
  --all             Uninstall all four components

  -h, --help        Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --nkp-url "https://portal.nutanix.com/..."
  $SCRIPT_NAME --skip-docker --dry-run
  $SCRIPT_NAME --uninstall
  $SCRIPT_NAME --uninstall --kubectl --nkp
  $SCRIPT_NAME --uninstall --all

EOF
}

# --- Main ---
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-docker)   SKIP_DOCKER=true ;;
      --skip-kubectl)  SKIP_KUBECTL=true ;;
      --skip-helm)     SKIP_HELM=true ;;
      --skip-nkp)      SKIP_NKP=true ;;
      --nkp-url)       NKP_URL="${2:-}"; shift 2; continue ;;
      --dry-run)       DRY_RUN=true ;;
      --verify-only)   VERIFY_ONLY=true ;;
      --log-file)      LOG_FILE="${2:-}"; shift 2; continue ;;
      --uninstall)     UNINSTALL_MODE=true ;;
      --docker)        UNINSTALL_DOCKER=true ;;
      --kubectl)        UNINSTALL_KUBECTL=true ;;
      --helm)          UNINSTALL_HELM=true ;;
      --nkp)           UNINSTALL_NKP=true ;;
      --all)           UNINSTALL_DOCKER=true; UNINSTALL_KUBECTL=true; UNINSTALL_HELM=true; UNINSTALL_NKP=true ;;
      -h|--help)       usage; exit 0 ;;
      *)               log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  [[ -z "${LOG_FILE:-}" ]] && LOG_FILE="${TMPDIR:-/tmp}/install-nkp-deps.$$.log"
  : > "$LOG_FILE"

  if [[ "$UNINSTALL_MODE" == true ]]; then
    log_info "Starting NKP dependency uninstaller (OS will be detected)."
    detect_os
    if [[ "$UNINSTALL_DOCKER" != true && "$UNINSTALL_KUBECTL" != true && "$UNINSTALL_HELM" != true && "$UNINSTALL_NKP" != true ]]; then
      prompt_uninstall_components
    fi
    do_uninstall_docker
    do_uninstall_kubectl
    do_uninstall_helm
    do_uninstall_nkp
    remove_completion_block
    log_info "Uninstall finished. Log written to $LOG_FILE"
    log_info "Run 'hash -r' (bash) or 'rehash' (zsh) so uninstalled commands are no longer looked up from cache—or open a new terminal."
    exit 0
  fi

  log_info "Starting NKP dependency installer (OS will be detected)."
  detect_os

  if [[ "$VERIFY_ONLY" == true ]]; then
    verify_versions
    exit $?
  fi

  install_prereqs
  install_docker
  install_kubectl
  install_helm
  install_nkp
  configure_completion

  if ! verify_versions; then
    log_error "Installation completed but version verification failed."
    exit 1
  fi

  log_info "Installation complete. Log written to $LOG_FILE"
  if [[ "$OS_TYPE" == linux ]] && [[ "$SKIP_DOCKER" != true ]]; then
    log_info "If you were added to the docker group, log out and back in (or run 'newgrp docker') for it to take effect."
  fi
}

main "$@"
