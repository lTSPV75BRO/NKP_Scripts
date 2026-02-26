#!/usr/bin/env bash
# Thin wrapper: run install-nkp-deps.sh in uninstall mode.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec "$SCRIPT_DIR/install-nkp-deps.sh" --uninstall "$@"
