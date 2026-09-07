#!/usr/bin/env bash
# Coding agent setup for macOS -- Claude Code, Codex, OpenCode.
#
# The logic is OS-neutral and lives in shared/agents.sh; this wrapper only
# supplies the macOS install hints. See that file for what gets wired where.
#
# Skip: MACHINIST_SKIP_AGENTS=1 ./run.sh --only agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../utils/utils.sh
source "$SCRIPT_DIR/../utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

if should_skip_step AGENTS; then
    log_info "Skipping agents (MACHINIST_SKIP_AGENTS is set)."
    exit 0
fi

export AGENT_HINT_CLAUDE="brew install --cask claude-code"
export AGENT_HINT_CODEX="brew install --cask codex"
export AGENT_HINT_OPENCODE="brew install opencode"

# shellcheck source=../../shared/agents.sh
source "$REPO_ROOT/shared/agents.sh"
configure_agents
