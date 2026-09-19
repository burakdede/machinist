#!/usr/bin/env bash
# Coding agent configuration hub -- shared by macOS and Ubuntu.
#
# This file contains no OS-specific logic. It is sourced by the macOS and
# Ubuntu agent steps, which install the vendor-native CLIs and configure them.
#
# ── The idea ──────────────────────────────────────────────────────────────────
# One instructions file drives both supported agents:
#
#   dotfiles/.config/agents/instructions.md
#     -> ~/.claude/CLAUDE.md              (Claude Code, symlink)
#     -> ~/.codex/AGENTS.md               (Codex, symlink)
#
# Edit that one file and both agents pick the change up.
#
# ── Why no model is pinned ────────────────────────────────────────────────────
# These configs deliberately do NOT hardcode a model id. Model names change
# often, and a stale id committed to a dotfiles repo silently pins a fresh
# machine to an old model, or names one that no longer exists. Each CLI's own
# default is a better answer; set a model per machine with the tool's own
# `/model` command if you want something specific.

AGENTS_CONFIG_DIR="$HOME/.config/agents"
CENTRAL_INSTRUCTIONS="$AGENTS_CONFIG_DIR/instructions.md"

# Symlink $2 -> $1, backing up an existing regular file first.
link_agent_instructions() {
    local source_file="$1"
    local target="$2"
    local label="$3"

    mkdir -p "$(dirname "$target")"

    if [[ -L "$target" ]]; then
        if [[ "$(readlink "$target")" == "$source_file" ]]; then
            log_info "$label: instructions symlink already in place"
            return 0
        fi
        rm -f "$target"
    elif [[ -e "$target" ]]; then
        mv "$target" "${target}.bak"
        log_info "$label: backed up existing $(basename "$target") to $(basename "$target").bak"
    fi

    ln -s "$source_file" "$target"
    log_success "$label: $(basename "$target") -> $source_file"
}

check_agent_installed() {
    local command_name="$1"
    local label="$2"
    local hint="$3"

    if command -v "$command_name" &>/dev/null; then
        log_success "$label $("$command_name" --version 2>/dev/null | head -1)"
        return 0
    fi

    log_warn "$label not found -- install: $hint"
    return 1
}

install_native_agents() {
    echo_header "Coding agent CLIs"

	if ! command_exists claude || upgrade_enabled; then
		log_info "Installing Claude Code with Anthropic's native installer..."
		curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
			https://claude.ai/install.sh | bash
	else
		log_info "Claude Code is already installed."
	fi

	if ! command_exists codex || upgrade_enabled; then
		log_info "Installing Codex with OpenAI's standalone installer..."
		curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
			https://chatgpt.com/codex/install.sh | sh
	else
		log_info "Codex is already installed."
	fi
}

configure_agents() {
    echo_header "Coding agents (Claude Code · Codex)"

    local agents_ok=1
    check_agent_installed claude   "Claude Code" "${AGENT_HINT_CLAUDE:-see claude.ai/code}"   || agents_ok=0
    check_agent_installed codex    "Codex"       "${AGENT_HINT_CODEX:-see openai.com/codex}"  || agents_ok=0

    # dotfiles.sh symlinks ~/.config/agents from the repo. If that step has not
    # run yet there is nothing to point the agents at.
    if [[ ! -f "$CENTRAL_INSTRUCTIONS" ]]; then
        log_warn "$CENTRAL_INSTRUCTIONS not found."
        log_warn "Run the dotfiles step first, then re-run: ./run.sh --only agents"
        return 0
    fi
    mkdir -p "$AGENTS_CONFIG_DIR/memory"

    # ─── Claude Code ──────────────────────────────────────────────────────────
    # Reads ~/.claude/CLAUDE.md as the global system prompt.
    link_agent_instructions "$CENTRAL_INSTRUCTIONS" "$HOME/.claude/CLAUDE.md" "Claude Code"

    # ─── Codex ────────────────────────────────────────────────────────────────
    # Reads ~/.codex/AGENTS.md as its global instructions. config.toml is left
    # to Codex itself: it holds auth and machine state, and overwriting it
    # would clobber project trust entries.
    link_agent_instructions "$CENTRAL_INSTRUCTIONS" "$HOME/.codex/AGENTS.md" "Codex"

    echo ""
    log_success "Central agent config: $AGENTS_CONFIG_DIR"
    log_success "  Edit $CENTRAL_INSTRUCTIONS to update instructions for both agents."

    if [[ "$agents_ok" -eq 0 ]]; then
        log_warn "One or more agents were not found -- install them and re-run: ./run.sh --only agents"
    fi
}
