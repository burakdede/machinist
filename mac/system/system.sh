#!/usr/bin/env bash
# macOS system bootstrap: Homebrew, Brew packages, mise, Nerd Fonts.
#
# ── Customisation ─────────────────────────────────────────────────────────────
# Packages:  edit Brewfile at the repo root.
# Fonts:     add/remove cask entries with "font-*" in Brewfile.
# mise:      see ~/.config/mise/ for tool version management after install.
#
# To upgrade all packages later:
#   brew upgrade && brew upgrade --cask
#
# To upgrade mise:
#   mise self-update
#
# Skip mise install:   MACHINIST_SKIP_MISE=1 ./run.sh --only system
# Force reinstall:     MACHINIST_UPGRADE=1 ./run.sh --only system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/utils.sh
source "$SCRIPT_DIR/../utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BREWFILE="$SCRIPT_DIR/../Brewfile"
UV_TOOLS_FILE="$REPO_ROOT/packages/uv-tools.txt"
NPM_PACKAGES_FILE="$REPO_ROOT/packages/npm-packages.txt"

# Same location as on Linux, so the single activation line in .zshrc and
# .zprofile works on both platforms without OS branching.
MISE_BIN="$HOME/.local/bin/mise"

load_versions

install_llama_cli() {
	echo_header "Llama CLI"

	if command_exists llama && ! upgrade_enabled; then
		log_info "llama is already installed. (MACHINIST_UPGRADE=1 to upgrade)"
		return 0
	fi

	log_info "Installing the Llama CLI via the official installer..."
	if curl --proto '=https' --tlsv1.2 -fsSL https://llama.app/install.sh | sh; then
		log_success "Llama CLI installed."
	else
		log_warn "The Llama CLI installer failed; continuing without it."
	fi
}

install_homebrew() {
    echo_header "Homebrew"

    if command_exists brew; then
        log_info "Homebrew $(brew --version | head -1) already installed."
        log_info "Updating Homebrew..."
        brew update
        return 0
    fi

    log_info "Installing Homebrew..."
    if ! command_exists xcode-select; then
        log_error "xcode-select not found. Install Xcode Command Line Tools first:"
        log_info "  xcode-select --install"
        exit 1
    fi
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    log_success "Homebrew installed."

    # Add Homebrew to current shell PATH (Apple Silicon vs Intel).
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

install_brew_packages() {
    echo_header "Homebrew packages (Brewfile)"

    if [[ ! -f "$BREWFILE" ]]; then
        log_warn "Brewfile not found at $BREWFILE; skipping."
        return 0
    fi

    # --no-lock was removed from `brew bundle`; lockfile generation no longer
    # exists, so passing it aborts the whole step.
    brew bundle install --file="$BREWFILE"
    brew cleanup -s
    log_success "Homebrew packages installed."
}

install_mise() {
    echo_header "mise (runtime version manager)"

    if should_skip_step MISE; then
        log_info "Skipping mise (MACHINIST_SKIP_MISE is set)."
        return 0
    fi

    # Test for $MISE_BIN specifically, NOT `command -v mise`. A Homebrew-managed
    # mise on PATH would satisfy `command -v` while leaving ~/.local/bin/mise
    # absent, and the activation lines in .zshrc and .zprofile reference that
    # exact path -- so mise would silently never activate.
    local want="${MISE_VERSION:-}"
    local got=""
    [[ -x "$MISE_BIN" ]] && got="$("$MISE_BIN" --version 2>/dev/null | awk '{print $2}')"

    if [[ -n "$got" ]] && ! upgrade_enabled && [[ -z "$want" || "$got" == "$want" ]]; then
        log_info "mise $got is already installed."
    else
        [[ -n "$got" ]] && log_info "mise installed: $got  pinned: ${want:-latest} -- reinstalling."
        log_info "Installing mise ${want:-latest} via official installer..."
        if [[ -n "$want" ]]; then
            MISE_VERSION="$want" curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
        else
            curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
        fi
        log_success "mise installed to $MISE_BIN"
    fi

    # A leftover Homebrew mise is harmless (~/.local/bin precedes /opt/homebrew
    # /bin in PATH) but is a second copy to keep updated. Flag it.
    if brew list --formula 2>/dev/null | grep -qx mise; then
        log_warn "Homebrew also has mise installed. It is no longer in the Brewfile;"
        log_warn "remove the duplicate with: brew uninstall mise"
    fi

    export PATH="$HOME/.local/bin:$PATH"
}

install_mise_runtimes() {
    echo_header "Language runtimes via mise"

    # Versions come from the shared dotfiles/.config/mise/config.toml, so macOS
    # and Ubuntu resolve to the same python/node/go.
    # Force a precompiled Python build. Without these mise falls back to
    # compiling CPython from source, which takes many minutes on a fresh
    # machine and needs a full build toolchain.
    MISE_PYTHON_COMPILE=0 \
    MISE_PYTHON_PRECOMPILED_FLAVOR=install_only_stripped \
        "$MISE_BIN" install
    log_success "Runtimes installed: $("$MISE_BIN" ls --current 2>/dev/null | awk '{printf "%s@%s ", $1, $2}')"
}

# Rust comes from rustup on both platforms rather than from Homebrew, so that
# `rustup component add` / `rustup target add` work the same way on each and
# the toolchain version is pinned from packages/versions.txt.
install_rust() {
    echo_header "Rust via rustup"

    if should_skip_step RUST; then
        log_info "Skipping Rust (MACHINIST_SKIP_RUST is set)."
        return 0
    fi
    if [[ -z "${RUST_VERSION:-}" ]]; then
        log_warn "RUST_VERSION not set in packages/versions.txt; skipping Rust."
        return 0
    fi

    if ! command_exists rustup; then
        curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
        # shellcheck source=/dev/null
        [[ -r "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
    else
        log_info "rustup is already installed."
    fi

    rustup toolchain install "$RUST_VERSION" --profile minimal --no-self-update
    rustup default "$RUST_VERSION"
}

# Playwright drives a real browser for visual verification; the npm package
# alone cannot do anything without one. Browser binaries are pinned to the
# playwright package version, so this runs after every upgrade -- `install` is
# a no-op when the matching browser is already cached.
#
# Chromium only: it covers screenshots, navigation and DOM assertions, and
# adding Firefox plus WebKit would triple the ~400MB for little day-to-day
# gain. Projects needing cross-browser run `npx playwright install` themselves.
install_playwright_browser() {
    echo_header "Playwright browser"

    if ! "$MISE_BIN" exec -- playwright --version >/dev/null 2>&1; then
        log_warn "playwright CLI not found; skipping the browser download."
        log_info "It comes from packages/npm-packages.txt -- re-run the system step."
        return 0
    fi

    # macOS needs no extra system packages, so plain `install`.
    if "$MISE_BIN" exec -- playwright install chromium; then
        log_success "Chromium ready ($("$MISE_BIN" exec -- playwright --version))"
    else
        log_warn "Could not install the Chromium build. Retry with:"
        log_info "  playwright install chromium"
    fi
}

install_uv_tools() {
    echo_header "uv tools"

    if [[ ! -f "$UV_TOOLS_FILE" ]]; then
        log_warn "Missing ${UV_TOOLS_FILE}; skipping uv tools."
        return 0
    fi
    if ! command_exists uv; then
        log_warn "uv not found; skipping uv tools. It is in the Brewfile."
        return 0
    fi

    local entry package_name source
    while IFS= read -r entry; do
        package_name="${entry%%|*}"
        source=""
        [[ "$entry" == *"|"* ]] && source="${entry#*|}"

        log_info "Installing uv tool: $package_name"
        if [[ -n "$source" ]]; then
            uv tool install --quiet --from "$source" "$package_name" \
                || uv tool upgrade "$package_name" \
                || log_warn "Could not install $package_name from $source"
        else
            uv tool install --quiet "$package_name" || uv tool upgrade "$package_name"
        fi
    done < <(read_list_file "$UV_TOOLS_FILE")
}

install_npm_clis() {
    echo_header "Node-based tooling"

    if [[ ! -f "$NPM_PACKAGES_FILE" ]]; then
        log_warn "Missing ${NPM_PACKAGES_FILE}; skipping npm CLIs."
        return 0
    fi

    local package_name
    while IFS= read -r package_name; do
        # Entries may be `package|command`; npm only wants the package.
        package_name="${package_name%%|*}"
        log_info "Installing npm package: $package_name"
        "$MISE_BIN" exec node -- npm install --global "$package_name"
    done < <(read_list_file "$NPM_PACKAGES_FILE")
}

main() {
    check_root

    install_homebrew
    install_brew_packages
    install_mise
    install_mise_runtimes
    install_rust
    install_uv_tools
    install_npm_clis
    install_playwright_browser
    install_llama_cli

    echo_header "System setup complete"
    log_success "Homebrew packages, mise runtimes and CLI tooling are ready."
    log_info "Next: run dotfiles and shell steps."
}

main
