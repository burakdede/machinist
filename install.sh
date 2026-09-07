#!/usr/bin/env bash
# machinist -- one entry point for both machines.
#
#   ./install.sh                 full bootstrap for whichever OS this is
#   ./install.sh --verify        health check, installs nothing
#   ./install.sh --only shell    run a single step
#   ./install.sh --help          all options for this platform
#
# Detects the operating system and hands off to mac/run.sh or linux/run.sh.
# Every argument is forwarded untouched, so anything the platform script
# accepts works here too.
#
# ── Why this file is bash 3.2 compatible ──────────────────────────────────────
# macOS still ships bash 3.2 (2007), and this runs before Homebrew has
# installed anything. So: no mapfile, no ${var^^}, no associative arrays, and
# no `exec {fd}>&1`. The macOS CI job enforces that.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Terminal output: colour and boxes on a tty, plain text when piped. Lives in
# shared/ui.sh so install.sh and every step below it render identically, and so
# there is one place that knows about terminal width and UTF-8 support.
# shellcheck source=shared/ui.sh
. "$REPO_ROOT/shared/ui.sh"

die() { ui_err "$*"; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
# Both platform scripts need these before they can do anything useful, and the
# failure is much clearer here than three steps deep.
require_prereqs() {
    local missing=""
    local tool
    for tool in git curl; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [ -z "$missing" ] && return 0

    ui_err "Missing required tool(s):$missing"
    case "$(uname -s)" in
        Darwin) die "Install the Xcode Command Line Tools first:  xcode-select --install" ;;
        *)      die "Install them first, e.g.:  sudo apt-get install -y${missing}" ;;
    esac
}

# ─── OS detection ─────────────────────────────────────────────────────────────
# Sets PLATFORM_DIR and PLATFORM_NAME, or exits with a message explaining
# exactly what was found and what is supported.
detect_platform() {
    local kernel
    kernel="$(uname -s)"

    case "$kernel" in
        Darwin)
            PLATFORM_DIR="$REPO_ROOT/mac"
            PLATFORM_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -m))"
            ;;
        Linux)
            [ -r /etc/os-release ] || die "Linux detected but /etc/os-release is missing; cannot identify the distribution."
            # shellcheck disable=SC1091
            . /etc/os-release

            case "${ID:-}${ID_LIKE:-}" in
                *ubuntu*|*debian*) ;;
                *) die "This setup targets Ubuntu LTS. Found '${PRETTY_NAME:-${ID:-unknown}}', which is not supported." ;;
            esac

            PLATFORM_DIR="$REPO_ROOT/linux"
            PLATFORM_NAME="${PRETTY_NAME:-Linux} ($(uname -m))"

            # Warn, do not block: a non-LTS release usually works, it is just
            # not what CI exercises.
            case "${VERSION_ID:-}" in
                22.04|24.04) ;;
                "") ui_warn "Could not determine the Ubuntu version; proceeding anyway." ;;
                *)  ui_warn "Ubuntu ${VERSION_ID} is not an LTS release. CI only covers LTS, so expect rough edges." ;;
            esac
            ;;
        *)
            die "Unsupported operating system: $kernel. This setup targets macOS and Ubuntu LTS."
            ;;
    esac

    [ -x "$PLATFORM_DIR/run.sh" ] || die "Expected $PLATFORM_DIR/run.sh to exist and be executable. Is the clone complete?"
}

main() {
    require_prereqs
    detect_platform

    ui_header "machinist"
    ui_ok "Detected  $PLATFORM_NAME"
    ui_ok "Running   ${PLATFORM_DIR#"$REPO_ROOT"/}/run.sh $*"

    # This repo's own git hooks. Cheap, idempotent, and unrelated to which OS
    # we are on, so it happens here rather than as a platform step.
    if [ -d "$REPO_ROOT/.git" ] && [ -x "$REPO_ROOT/scripts/install-hooks.sh" ]; then
        ui_ok "$("$REPO_ROOT/scripts/install-hooks.sh")"
    fi

    # So the platform script prints the command you actually typed.
    export MACHINIST_ENTRY="./install.sh"

    cd "$PLATFORM_DIR"
    exec ./run.sh "$@"
}

main "$@"
