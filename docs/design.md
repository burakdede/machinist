# Design decisions

[← back to README](../README.md)

## What this setup decides for you

It is opinionated. If you are adopting it, these are the choices you are
inheriting.

| Concern | Choice | Why |
|---|---|---|
| Shell | zsh + antidote + powerlevel10k | Fast, no framework; plugins are a plain text list; see [Shell](shell.md) |
| Runtimes | mise, one shared config | Python, Node, Go, and the IaC tooling in one pinned file |
| JVM | SDKMAN | mise cannot install GraalVM or the Spring Boot CLI; see [JVM toolchain](jvm.md) |
| Python CLIs | uv | Isolated tool installs, no global pip |
| Terminal | WezTerm | Same config and same keys on both platforms; see [Terminal](terminal.md) |
| Multiplexer | tmux, OSC 52 clipboard | Copy behaves identically on macOS and Ubuntu, and over SSH; see [`tmux.conf`](../dotfiles/.config/tmux/tmux.conf) |
| Editor | Neovim + lazy.nvim, with Zed as the visual backup | Neovim remains the primary terminal editor; Zed uses native platform installers and its own update path |
| Prompt | powerlevel10k with instant prompt | |

**One runtime manager, not several.** mise owns Python, Node and Go; SDKMAN
owns the JVM. `pyenv`, `rbenv`, `nodenv`, `nvm`, `asdf`, `goenv` and `jenv` all
shadow the mise shims for the same runtime, and which version you get then
depends on PATH order rather than on the config in this repo. `--verify` warns
when it finds one, and reports whether `node` and `python` actually resolve
through mise.

If you are migrating from one of them, uninstall it rather than leaving it
alongside mise, and move its pinned versions into
`dotfiles/.config/mise/config.toml` first:

```bash
brew uninstall pyenv rbenv && rm -rf ~/.pyenv ~/.rbenv
```

**Agent skills are not vendored here.** Claude Code loads skills from
`~/.claude/skills` and its own plugin cache, never from
`~/.config/agents/skills`. Anything copied there is dead weight that the plugin
cache regenerates, so it is gitignored. Only `instructions.md` is shared.

**The Brewfile is the source of truth for macOS packages.** If you install
things by hand it will drift, and `--verify` will tell you so. Reconcile with
`brew bundle install --file=mac/Brewfile`, or add what you installed to the
Brewfile. GUI apps you do not want are worth deleting from the Brewfile rather
than leaving permanently unsatisfied.

**Nothing here pins an LLM model id.** Agent configs use each CLI's own
default; see the Coding agents section.

## Extending

- **New macOS step:** add a script under `mac/<stepname>/<stepname>.sh`, wire it into `mac/run.sh` steps array.
- **New Linux step:** add a script under `linux/<stepname>/<stepname>.sh`, wire it into `linux/run.sh` steps array.
- **Shared config:** add files under `dotfiles/` -- they are automatically symlinked by both platform dotfiles scripts.
- **macOS-only config:** add under `mac/configs/.config/<toolname>/` -- symlinked by `mac/dotfiles.sh`.
