#!/usr/bin/env bash
# Linux Setup -- Orchestration Script

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

INCLUDE_GIT=1
INCLUDE_SETTINGS=1
ONLY_STEPS=()
VERIFY_ONLY=0
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_STARTED="$(date +%s)"
LOG_FILE="${MACHINIST_LOG_FILE:-$HOME/.local/state/machinist/logs/linux-run-${RUN_TS}.log}"
LOGGING_INITIALIZED=0
LOG_PIPE=""
LOG_TEE_PID=""
SAVED_STDIO=0

usage() {
    cat <<EOF
Usage: ${MACHINIST_ENTRY:-./run.sh} [options]

Options:
  --include-git       Include GitHub SSH setup step (default: enabled).
  --include-settings  Include GNOME desktop preferences step (default: enabled).
  --skip-git          Skip GitHub SSH setup step.
  --skip-settings     Skip GNOME desktop preferences step.
  --only STEP         Run only a single step. Repeatable.
  --help              Show this help text.

Valid STEP values (run in this order on a fresh machine):
  system          APT packages, runtimes, fonts, core CLI tooling
  dotfiles        Symlink config files into \$HOME
  configure       Git identity prompts -- writes to ~/.gitconfig.local
  shell           Install zsh and set it as the default login shell
  sdk             SDKMAN toolchain (Java, Kotlin, …)
  editor          Install Neovim, register as vim/vi/editor
  multiplexer     Tmux TPM bootstrap and config wiring
  terminal        Install WezTerm, set as default terminal
  agents          Claude Code, Codex, OpenCode -- install checks + central config symlinks
  git             GitHub SSH key setup (interactive)
  settings        GNOME desktop preferences (requires desktop session)

  --verify        Print a ✓/✗ summary of installed tools without installing.

Environment variable overrides (identical on macOS and Ubuntu):
  MACHINIST_UPGRADE=1            Re-install tools even if already present.
  MACHINIST_SYSTEM_UPGRADE=1     Run apt upgrade and autoremove during system setup.
  MACHINIST_SKIP_<STEP>=1        Skip a specific step, e.g. MACHINIST_SKIP_SDK=1
  MACHINIST_GIT_NAME / _EMAIL    Pre-seed git identity for unattended runs.
  MACHINIST_LOG_FILE             Override the run log path.

Dependencies:
  - Run system first on a fresh machine; all other steps need its packages.
  - configure needs dotfiles (for the .gitconfig symlink).
  - terminal picks up zsh as its default shell only after shell has run.
  - editor's Java LSP (jdtls) needs a JDK -- run sdk before opening Java files.
  - agents needs system packages (npm for claude-code, etc.) -- run system first.
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
    if [[ ${#ONLY_STEPS[@]} -eq 0 ]]; then
        return 0
    fi
    contains_step "$step"
}

# Emit a warning when a dependency step is not in the selected set.
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

    echo_header "Starting: ${description}"
    # Named in the failure message and in the resume command; see handle_error.
    MACHINIST_STEP="$step" bash "$script_path"
    log_success "Completed: ${description}"
}

init_run_logging() {
    if [[ "$LOGGING_INITIALIZED" -eq 1 ]]; then
        return 0
    fi
    local requested_log="$LOG_FILE"
    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then
        LOG_FILE="${TMPDIR:-/tmp}/machinist-linux-logs/run-${RUN_TS}.log"
        if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then
            log_warn "Could not create run log at '$requested_log' or fallback '$LOG_FILE'. Continuing without persistent run log."
            LOG_FILE="$requested_log"
            LOGGING_INITIALIZED=0
            return 0
        fi
        log_warn "Could not write run log at '$requested_log'. Using fallback log path '$LOG_FILE'."
    fi

    # Use a named pipe instead of process substitution for wider compatibility.
    LOG_PIPE="$(mktemp -u "${TMPDIR:-/tmp}/machinist-log.XXXXXX")"
    if mkfifo "$LOG_PIPE"; then
        # Fixed descriptors 3 and 4, matching mac/run.sh. The auto-allocating
        # `exec {VAR}>&1` form needs bash 4.1; keeping both entry points on the
        # portable spelling means they behave identically.
        exec 3>&1 4>&2
        SAVED_STDIO=1
        tee -a "$LOG_FILE" < "$LOG_PIPE" &
        LOG_TEE_PID="$!"
        exec > "$LOG_PIPE" 2>&1
        LOGGING_INITIALIZED=1
        return 0
    fi

    # Fallback: continue without stream duplication if FIFO setup fails.
    LOGGING_INITIALIZED=0
}

cleanup_run_logging() {
    # Restore stdout/stderr first so the FIFO writer closes and tee can exit.
    if [[ "$SAVED_STDIO" -eq 1 ]]; then
        exec 1>&3 2>&4 || true
        exec 3>&- 4>&- || true
        SAVED_STDIO=0
    fi

    if [[ -n "$LOG_PIPE" && -p "$LOG_PIPE" ]]; then
        rm -f "$LOG_PIPE" || true
    fi
    if [[ -n "$LOG_TEE_PID" ]]; then
        wait "$LOG_TEE_PID" 2>/dev/null || true
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-git)
            INCLUDE_GIT=1
            ;;
        --include-settings)
            INCLUDE_SETTINGS=1
            ;;
        --skip-git)
            INCLUDE_GIT=0
            ;;
        --skip-settings)
            INCLUDE_SETTINGS=0
            ;;
        --only)
            shift
            if [[ $# -eq 0 ]]; then
                log_error "--only requires a step name."
                exit 1
            fi
            ONLY_STEPS+=("$1")
            ;;
        --verify)
            VERIFY_ONLY=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            exit 1
            ;;
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

    # Defaults for display/font quality in GNOME settings step.
    # Users can override any of these env vars when invoking run.sh.
    export MACHINIST_TEXT_SCALE="${MACHINIST_TEXT_SCALE:-1.15}"
    export MACHINIST_CURSOR_SIZE="${MACHINIST_CURSOR_SIZE:-32}"
    export MACHINIST_FONT_RGBA_ORDER="${MACHINIST_FONT_RGBA_ORDER:-rgb}"
    export MACHINIST_FONT_ANTIALIASING="${MACHINIST_FONT_ANTIALIASING:-rgba}"
    export MACHINIST_FONT_HINTING="${MACHINIST_FONT_HINTING:-slight}"
    export MACHINIST_MONOSPACE_FONT="${MACHINIST_MONOSPACE_FONT:-JetBrainsMono Nerd Font 13}"

    local step_name
    local -a steps=(
        # 1. Base system -- everything else depends on this
        "system|$ROOT_DIR/system/system.sh|System packages and developer tooling"
        # 2. Dotfiles -- configs in place before any tool is configured
        "dotfiles|$ROOT_DIR/dotfiles.sh|Dotfiles"
        # 3. Identity -- needs .gitconfig symlinked by dotfiles
        "configure|$ROOT_DIR/configure/configure.sh|Interactive configuration"
        # 4. Shell -- change default shell early; later tools benefit from zsh being active
        "shell|$ROOT_DIR/shell/shell.sh|Zsh shell"
        # 5. Language SDKs -- jdtls in the editor needs a JDK
        "sdk|$ROOT_DIR/sdk/sdk.sh|SDKMAN toolchain"
        # 6. Editor + multiplexer -- independent of each other, depend on system
        "editor|$ROOT_DIR/editor/editor.sh|Neovim editor"
        "multiplexer|$ROOT_DIR/multiplexer/multiplexer.sh|Tmux multiplexer"
        # 7. Terminal -- launched last so it picks up zsh as default shell
        "terminal|$ROOT_DIR/terminal/terminal.sh|WezTerm terminal emulator"
        # 8. Agent tooling -- needs npm/node from system
        "agents|$ROOT_DIR/agents/agents.sh|Coding agents (Claude Code, Codex, OpenCode)"
    )

    if [[ $INCLUDE_GIT -eq 1 ]]; then
        steps+=("git|$ROOT_DIR/git/git.sh|GitHub SSH setup")
    fi

    if [[ $INCLUDE_SETTINGS -eq 1 ]]; then
        steps+=("settings|$ROOT_DIR/utils/settings.sh|GNOME desktop settings")
    fi

    echo_header "Ubuntu developer machine bootstrap"
    log_info "Run log: $LOG_FILE"
    log_info "Default run includes all steps; use --skip-git/--skip-settings for non-interactive mode."
    log_info "Display defaults: text-scale=$MACHINIST_TEXT_SCALE cursor-size=$MACHINIST_CURSOR_SIZE"
    log_info "Font defaults: rgba-order=$MACHINIST_FONT_RGBA_ORDER antialias=$MACHINIST_FONT_ANTIALIASING hinting=$MACHINIST_FONT_HINTING"
    log_info "Monospace font: $MACHINIST_MONOSPACE_FONT"

    # Warn about unmet dependencies when running with --only
    if [[ ${#ONLY_STEPS[@]} -gt 0 ]]; then
        # Every tool step needs system
        for step_name in shell editor multiplexer terminal sdk agents; do
            if contains_step "$step_name"; then
                check_step_deps "$step_name" system
            fi
        done
        # configure writes to .gitconfig.local -- only useful after dotfiles symlinks .gitconfig
        if contains_step configure; then
            check_step_deps configure dotfiles
        fi
        # terminal default_prog is zsh -- more useful once shell has set zsh as default
        if contains_step terminal; then
            check_step_deps terminal shell
        fi
        # jdtls (Java LSP in Neovim) needs a JDK from sdk
        if contains_step editor; then
            check_step_deps "editor (Java LSP)" sdk
        fi
    fi

    local total=0
    local record
    for record in "${steps[@]}"; do
        IFS='|' read -r step_name _ _ <<< "$record"
        if should_run_step "$step_name"; then
            total=$((total + 1))
        fi
    done

    if [[ $total -eq 0 ]]; then
        log_warn "No steps selected."
        exit 0
    fi

    local current=0
    local script_path
    local description
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
