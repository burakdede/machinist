#!/usr/bin/env bash
# Coding agent setup for macOS -- Claude Code and Codex CLIs.
#
# The logic is OS-neutral and lives in shared/agents.sh.
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

# shellcheck source=../../shared/agents.sh
source "$REPO_ROOT/shared/agents.sh"
install_native_agents
configure_agents
