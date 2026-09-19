# Coding agents

[← back to README](../README.md)

## Coding agents

`dotfiles/.config/agents/instructions.md` is the shared system prompt for the
supported CLI agents:

| Agent | How it reads the shared instructions |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` symlinked to it |
| Codex | `~/.codex/AGENTS.md` symlinked to it |

Edit `dotfiles/.config/agents/instructions.md` and both agents pick the change up.

The step is non-destructive: an existing `~/.codex/config.toml` is left alone
because it holds auth and project trust state.

**No model id is pinned.** Model names change often, and a stale id committed
to a dotfiles repo silently pins a fresh machine to an old model or names one
that no longer exists. Each CLI's own default is used; set a model per machine
with the tool's own `/model` command. (The previous template pinned Codex to
`o4-mini`, which was long dead.)

The logic is OS-neutral and lives in `shared/agents.sh`; both platform wrappers
run the same vendor-native installers before wiring the shared instructions.
