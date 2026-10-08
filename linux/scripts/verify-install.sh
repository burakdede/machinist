#!/usr/bin/env bash
# Post-install health check for Ubuntu.
#
# Cross-platform checks live in shared/verify.sh; this file adds only the
# Ubuntu-specific ones. Installs nothing -- safe to run at any time.
#
# Usage:
#   ./run.sh --verify
#   bash scripts/verify-install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
# shellcheck source=../utils/utils.sh
source "$ROOT_DIR/utils/utils.sh"
# shellcheck source=../../shared/verify.sh
source "$REPO_ROOT/shared/verify.sh"

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.cargo/bin:$PATH"

echo_header "machinist verification (Ubuntu)"

verify_shared

section "Ubuntu-only tools"
check_file "$HOME/Applications/LM Studio.AppImage" "LM Studio"
check_cmd_optional wezterm
check_cmd_optional docker
check_cmd shellcheck
check_cmd shfmt
check_cmd just
check_cmd direnv

section "Clipboard"
# Neovim's clipboard=unnamedplus needs a matching provider for the session type.
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    check_cmd wl-copy "wl-clipboard (Wayland session)"
else
    check_cmd xclip "xclip (X11 session)"
fi

section "Architecture"
ok "$(dpkg --print-architecture) / $(uname -m)"
if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    warn "Google Chrome and Spotify have no build for this architecture and are skipped"
fi

section "Command alternatives"
# APT installs these under different names; the system step symlinks them.
for pair in "fd:fdfind" "bat:batcat"; do
    cmd="${pair%%:*}"; apt_name="${pair##*:}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd  (APT ships it as $apt_name)"
    else
        fail "$cmd  (missing -- APT installs $apt_name; the symlink was not created)"
    fi
done

section "Shell"
if [[ "$(getent passwd "$USER" | cut -d: -f7)" == *zsh ]]; then
    ok "login shell is zsh"
else
    warn "login shell is not zsh  (run: ./run.sh --only shell, then log out and back in)"
fi

verify_summary
