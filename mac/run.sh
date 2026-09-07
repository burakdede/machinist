#!/usr/bin/env bash
# macOS Setup -- Orchestration Script
#
# ── Quick start ───────────────────────────────────────────────────────────────
#   git clone https://github.com/burakdede/machinist.git
#   cd <clone>/mac
#
#   ./run.sh
#
# ── Step overview ─────────────────────────────────────────────────────────────
#  1. system      -- Homebrew, Brewfile packages, mise runtime manager
#  2. dotfiles    -- symlink shared configs into $HOME from dotfiles/
#  3. configure   -- interactive git identity prompts → ~/.gitconfig.local
#  4. shell       -- set zsh as default shell, install antidote + powerlevel10k
#  5. sdk         -- SDKMAN (Java, Kotlin, …)
#  6. editor      -- neovim + lazy.nvim plugin bootstrap, vi/vim shims
#  7. multiplexer -- tmux config wiring + TPM (Tmux Plugin Manager)
#  8. terminal    -- WezTerm via Homebrew Cask
#  9. agents      -- Claude Code, Codex, OpenCode -- install checks + central config symlinks
# 10. git         -- GitHub SSH key setup (interactive; skippable)
# 11. macos       -- macOS system defaults via `defaults write` (skippable)
#
# ── Syncing shared dotfiles ───────────────────────────────────────────────────
# The dotfiles/ directory lives at the repo root, shared between mac/ and linux/.
#
#
#
# To pull the latest dotfiles (after a git pull on machinist):
#   cd <clone> && git pull
#
#
# ── Environment variable overrides ───────────────────────────────────────────
# MACHINIST_UPGRADE=1           -- re-install tools even if already present
# MACHINIST_SKIP_<STEP>=1       -- skip a specific step (e.g. MACHINIST_SKIP_SDK)
# MACHINIST_GIT_NAME / _EMAIL   -- pre-seed git identity (non-interactive CI use)
# MACHINIST_PROMPT_TIMEOUT_SECONDS=N -- timeout for configure prompts (default 60)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/utils.sh
source "$ROOT_DIR/utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

INCLUDE_GIT=1
INCLUDE_MACOS=1
ONLY_STEPS=()
VERIFY_ONLY=0
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_STARTED="$(date +%s)"
LOG_FILE="${MACHINIST_LOG_FILE:-$HOME/.local/state/machinist/logs/mac-run-${RUN_TS}.log}"
LOGGING_INITIALIZED=0
LOG_PIPE=""
LOG_TEE_PID=""
SAVED_STDIO=0

usage() {
    cat <<EOF
Usage: ${MACHINIST_ENTRY:-./run.sh} [options]

Options:
  --skip-git          Skip GitHub SSH setup step (default: included).
  --skip-macos        Skip macOS system defaults step (default: included).
  --include-git       Explicitly include GitHub SSH setup step.
  --include-macos     Explicitly include macOS defaults step.
  --only STEP         Run only a single step. Repeatable.
  --verify            Print a ✓/✗ summary of installed tools without installing.
  --help              Show this help text.

Valid STEP values (run in this order on a fresh machine):
  system          Homebrew, Brewfile packages, mise runtime manager
  dotfiles        Symlink shared configs from dotfiles/ into \$HOME
  configure       Git identity prompts -- writes to ~/.gitconfig.local
  shell           Set zsh as default shell, install antidote + powerlevel10k
  sdk             SDKMAN toolchain (Java, Kotlin, …)
  editor          Neovim via Homebrew + lazy.nvim bootstrap, vi/vim shims
  multiplexer     Tmux config wiring + TPM (Tmux Plugin Manager)
  terminal        WezTerm via Homebrew Cask
  agents          Claude Code, Codex, OpenCode -- install checks + central config symlinks
  git             GitHub SSH key setup (interactive)
  macos           macOS system defaults via 'defaults write'

Dependencies:
  - Run system first on a fresh machine; other steps need its packages.
  - Run dotfiles before configure, shell, editor, multiplexer, terminal.
  - Run shell before terminal (terminal picks up the new default shell).
  - Run sdk before editor if you use Java LSP in Neovim (jdtls needs a JDK).
  - Run system before agents (agents needs Homebrew-installed agent CLIs).

Environment variable overrides (identical on macOS and Ubuntu):
  MACHINIST_UPGRADE=1            Re-install tools even if already present.
  MACHINIST_SKIP_<STEP>=1        Skip a specific step, e.g. MACHINIST_SKIP_SDK=1
  MACHINIST_GIT_NAME / _EMAIL    Pre-seed git identity for unattended runs.
  MACHINIST_LOG_FILE             Override the run log path.
EOF
}

contains_step() {
    local wanted="$1"
    local step
    for step in "${ONLY_STEPS[@]}"; do
        [[ "$step" == "$wanted" ]] && return 0
    done
    return 1
}

should_run_step() {
    local step="$1"
    [[ ${#ONLY_STEPS[@]} -eq 0 ]] && return 0
    contains_step "$step"
}

check_step_deps() {
    local step="$1"
    shift
    local dep
    for dep in "$@"; do
        if [[ ${#ONLY_STEPS[@]} -gt 0 ]] && ! contains_step "$dep"; then
            log_warn "Step '$step' may depend on '$dep' which is not in the selected steps."
        fi
    done
}

run_script() {
    local step="$1"
    local script_path="$2"
    local description="$3"

    if [[ ! -f "$script_path" ]]; then
        log_warn "Skipping ${description}; script not found at ${script_path}."
        return 0
    fi

    local started ended
    started="$(date +%s)"

    # MACHINIST_STEP is named in the failure message and the resume command.
    MACHINIST_STEP="$step" bash "$script_path"

    ended="$(date +%s)"
    ui_summary_add ok "$step" "$((ended - started))"
}

init_run_logging() {
    [[ "$LOGGING_INITIALIZED" -eq 1 ]] && return 0

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then
        LOG_FILE="${TMPDIR:-/tmp}/machinist-mac-logs/run-${RUN_TS}.log"
        if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then
            log_warn "Could not create run log. Continuing without persistent log."
            LOGGING_INITIALIZED=0
            return 0
        fi
        log_warn "Using fallback log path: $LOG_FILE"
    fi

    LOG_PIPE="$(mktemp -u "${TMPDIR:-/tmp}/machinist-log.XXXXXX")"
    if mkfifo "$LOG_PIPE"; then
        # Fixed descriptors 3 and 4, NOT the `exec {VAR}>&1` auto-allocating
        # form: that needs bash 4.1, and macOS still ships bash 3.2. This is the
        # entry point of the whole bootstrap, so it has to run on a stock Mac
        # before Homebrew (and a newer bash) exist.
        exec 3>&1 4>&2
        SAVED_STDIO=1
        tee -a "$LOG_FILE" < "$LOG_PIPE" &
        LOG_TEE_PID="$!"
        exec > "$LOG_PIPE" 2>&1
        LOGGING_INITIALIZED=1
    fi
}

cleanup_run_logging() {
    if [[ "$SAVED_STDIO" -eq 1 ]]; then
        exec 1>&3 2>&4 || true
        exec 3>&- 4>&- || true
        SAVED_STDIO=0
    fi
    [[ -n "$LOG_PIPE" && -p "$LOG_PIPE" ]] && rm -f "$LOG_PIPE" || true
    [[ -n "$LOG_TEE_PID" ]] && wait "$LOG_TEE_PID" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-git)       INCLUDE_GIT=0 ;;
        --skip-macos)     INCLUDE_MACOS=0 ;;
        --include-git)    INCLUDE_GIT=1 ;;
        --include-macos)  INCLUDE_MACOS=1 ;;
        --only)
            shift
            [[ $# -eq 0 ]] && { log_error "--only requires a step name."; exit 1; }
            ONLY_STEPS+=("$1")
            ;;
        --verify)         VERIFY_ONLY=1 ;;
        --help|-h)        usage; exit 0 ;;
        *)                log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
done

trap cleanup_run_logging EXIT

# What is actually left to do, rather than a fixed list printed every run.
# A checklist that says "log out to change your shell" when the shell already
# changed trains you to skip reading it.
print_outstanding() {
    local -a items=()

    # Shell change needs a re-login to take effect.
    local login_shell=""
    if command_exists dscl; then
        login_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
    else
        login_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"
    fi
    [[ "$login_shell" == *zsh ]] || items+=("log out and back in -- login shell is still ${login_shell:-unknown}")

    # gh drives the issue/PR workflow the agent instructions describe.
    if command_exists gh && ! gh auth status >/dev/null 2>&1; then
        items+=("gh auth login -- required for issues, PRs and projects")
    fi

    # Agent CLIs need an interactive login that cannot be scripted.
    local agent
    for agent in claude codex opencode; do
        command_exists "$agent" || items+=("install $agent")
    done

    if [[ ${#items[@]} -eq 0 ]]; then
        ui_ok "Nothing outstanding. Open a new terminal and go."
        return 0
    fi

    log_info "Outstanding:"
    local item
    for item in "${items[@]}"; do
        log_info "  - $item"
    done
    log_info ""
    log_info "Anything needing a browser login (agents, gh) has to be done by hand."
}

main() {
    init_run_logging

    if [[ $VERIFY_ONLY -eq 1 ]]; then
        log_info "Run log: $LOG_FILE"
        bash "$ROOT_DIR/scripts/verify-install.sh"
        log_info "Verification log saved to: $LOG_FILE"
        return 0
    fi

    check_root
    check_directory

    local step_name
    local -a steps=(
        "system|$ROOT_DIR/system/system.sh|Homebrew packages and developer tooling"
        "dotfiles|$ROOT_DIR/dotfiles.sh|Dotfiles (shared dotfiles/ directory)"
        "configure|$ROOT_DIR/configure/configure.sh|Interactive configuration (git identity)"
        "shell|$ROOT_DIR/shell/shell.sh|Zsh shell"
        "sdk|$ROOT_DIR/sdk/sdk.sh|SDKMAN toolchain"
        "editor|$ROOT_DIR/editor/editor.sh|Neovim editor"
        "multiplexer|$ROOT_DIR/multiplexer/multiplexer.sh|Tmux multiplexer"
        "terminal|$ROOT_DIR/terminal/terminal.sh|WezTerm terminal emulator"
        "agents|$ROOT_DIR/agents/agents.sh|Coding agents (Claude Code, Codex, OpenCode)"
    )

    [[ $INCLUDE_GIT -eq 1 ]]   && steps+=("git|$ROOT_DIR/git/git.sh|GitHub SSH setup")
    [[ $INCLUDE_MACOS -eq 1 ]] && steps+=("macos|$ROOT_DIR/macos/os-defaults.sh|macOS system defaults")

    echo_header "macOS developer machine bootstrap"
    log_info "Run log: $LOG_FILE"
    log_info "Use --skip-git to skip the interactive GitHub SSH step."
    log_info "Use --skip-macos to skip system defaults (safe to run later)."

    if [[ ${#ONLY_STEPS[@]} -gt 0 ]]; then
        for step_name in shell editor multiplexer terminal sdk agents; do
            contains_step "$step_name" && check_step_deps "$step_name" system
        done
        contains_step configure && check_step_deps configure dotfiles
        contains_step terminal  && check_step_deps terminal shell
        contains_step editor    && check_step_deps "editor (Java LSP)" sdk
    fi

    local total=0
    local record
    for record in "${steps[@]}"; do
        IFS='|' read -r step_name _ _ <<< "$record"
        should_run_step "$step_name" && total=$((total + 1))
    done

    if [[ $total -eq 0 ]]; then
        log_warn "No steps selected."
        exit 0
    fi

    local current=0
    local script_path description
    for record in "${steps[@]}"; do
        IFS='|' read -r step_name script_path description <<< "$record"
        if ! should_run_step "$step_name"; then
            ui_summary_add skip "$step_name" 0
            continue
        fi
        current=$((current + 1))
        ui_step "$current" "$total" "$step_name" "$description"
        run_script "$step_name" "$script_path" "$description"
    done

    ui_summary_print "$(( $(date +%s) - RUN_STARTED ))"
    log_success "Run log saved to: $LOG_FILE"
    print_outstanding
}

main
