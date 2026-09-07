# machinist

> A machinist doesn't start by cutting metal. They set up the machine first —
> square the vise, zero the tool, check the travel — because everything made
> afterwards inherits that setup.

Same idea, for a developer box. One clone turns a fresh macOS or Ubuntu LTS
machine into a workshop that is already set up: shell, editor, terminal,
multiplexer, runtimes, and the coding agents that use them — configured
identically on both, from one shared set of files.

It is opinionated, because a shop where every tool sits in a different place on
every bench is not a shop. What it decides for you, and why, is written down in
[Design decisions](docs/design.md).

```bash
git clone https://github.com/burakdede/machinist.git
cd machinist
./install.sh
```

HTTPS on purpose: a fresh machine has no SSH key yet — the `git` step is what
creates one. Switch the remote to SSH afterwards if you prefer.

Clone it wherever you like. Nothing depends on the path: every script resolves
its own location, and the dotfile symlinks point back at whatever clone you ran
`install.sh` from.

That is the whole thing. `install.sh` detects the operating system and runs the
right bootstrap, so there is nothing to remember per machine.

```bash
./install.sh                 # full bootstrap
./install.sh --verify        # health check, installs nothing
./install.sh --only shell    # re-run a single step
./install.sh --help          # every option for this platform
```

It is safe to re-run: every step skips work that is already done. If a step
fails it says which one, and prints the exact command to resume with. At the
end it lists only what is genuinely still outstanding.

Day two onwards, `just` is the entry point:

```bash
just            # list every task
just update     # brew/apt, mise, uv, sdkman, nvim plugins, mason, hooks
just verify     # health check
just test       # full suite
just bench      # shell startup, both shells
```

---

## Documentation

| Topic | What is in it |
|---|---|
| [Shell](docs/shell.md) | zsh and bash config, PATH rules, startup speed, aliases |
| [Terminal](docs/terminal.md) | WezTerm and tmux, keybindings, theming, fixing input problems |
| [Neovim](docs/neovim.md) | Plugins, LSP, treesitter, everyday workflows |
| [JVM toolchain](docs/jvm.md) | SDKMAN, GraalVM, Maven and Gradle |
| [Git](docs/git.md) | Config decisions, git-lfs and ssh wiring, the global gitignore |
| [Coding agents](docs/agents.md) | One instructions file shared by Claude Code, Codex and OpenCode |
| [Versions and packages](docs/versions.md) | Where each version is pinned, how to add a tool |
| [Verification and CI](docs/ci.md) | What `--verify` checks, what CI covers, post-install state |
| [Design decisions](docs/design.md) | What this setup chooses for you, and why |

Ubuntu-specific, since they have no macOS counterpart:

| Topic | What is in it |
|---|---|
| [Getting started](linux/docs/getting-started.md) | First run on a fresh Ubuntu box |
| [Customization](linux/docs/customization.md) | Package manifests, version pins, GNOME preferences |
| [Control map](linux/docs/control-map.md) | Keyboard shortcuts and desktop bindings |
| [Reference](linux/docs/reference.md) | Step-by-step reference for the Linux scripts |

---

## Layout

```
machinist/
├── dotfiles/          shared cross-platform configs (zsh, nvim, tmux, wezterm, …)
├── packages/          shared tool manifests (SDKMAN, uv, npm)
├── mac/               macOS setup scripts (Homebrew-based)
└── linux/             Ubuntu setup scripts (APT/GitHub-release-based)
```

`dotfiles/` is a plain directory -- no submodule. Edit a file, commit, push. Both machines pull the same change with `git pull`.

### The organising rule

macOS and Ubuntu are different operating systems with different desktop
environments, and this repo does not pretend otherwise. What it does guarantee
is that **anything shared is defined in exactly one place**, and anything
OS-specific lives in that OS's directory.

| Scope | Lives in | Examples |
|---|---|---|
| Shared config | `dotfiles/` | zsh, nvim, tmux, wezterm, git, mise |
| Shared tool lists | `packages/` | SDKMAN candidates, uv tools, npm CLIs |
| OS-specific packages | `mac/`, `linux/` | Brewfile casks, APT, GitHub-release binaries |
| OS-specific behaviour | `mac/`, `linux/` | `defaults write`, GNOME settings, `chsh` vs `usermod` |

So the JVM candidates you get are identical on both machines because they come
from one file, while the window manager and the clipboard daemon are
necessarily different. If you add a cross-platform CLI tool to an OS-specific
list, that is how the two machines drift apart.

---

## What gets installed

### macOS (`mac/`)

| Step | What it does |
|---|---|
| `system` | Homebrew + all packages in `Brewfile`, mise runtime manager |
| `dotfiles` | Symlinks `dotfiles/` and `mac/configs/` into `$HOME` |
| `configure` | Prompts for git name/email → writes `~/.gitconfig.local` |
| `shell` | Sets Homebrew zsh as default shell, installs antidote + powerlevel10k |
| `sdk` | SDKMAN -- Java, Kotlin |
| `editor` | Neovim via Homebrew, `vi`/`vim` shims, lazy.nvim plugin bootstrap |
| `multiplexer` | Tmux config wiring + TPM (Tmux Plugin Manager) |
| `terminal` | WezTerm via Homebrew Cask |
| `agents` | Claude Code, Codex, OpenCode -- install checks + central config symlinks |
| `git` | GitHub SSH key generation and connection test |
| `macos` | macOS system defaults via `defaults write` |

Run a single step: `./run.sh --only editor`  
Skip a step: `MACHINIST_SKIP_SDK=1 ./run.sh`  
Re-install: `MACHINIST_UPGRADE=1 ./run.sh --only editor`

### Linux (`linux/`)

| Step | What it does |
|---|---|
| `system` | APT packages, GitHub-release binaries, cloud CLIs, mise, Nerd Fonts |
| `dotfiles` | Symlinks `dotfiles/` into `$HOME` |
| `configure` | Prompts for git name/email → writes `~/.gitconfig.local` |
| `shell` | Installs zsh, sets it as default shell |
| `sdk` | SDKMAN -- Java, Kotlin |
| `editor` | Neovim from GitHub releases, `vi`/`vim`/`editor` alternatives |
| `multiplexer` | Tmux config wiring + TPM |
| `terminal` | WezTerm from GitHub releases, sets as default terminal |
| `agents` | Claude Code, Codex, OpenCode -- install checks + central config symlinks |
| `git` | GitHub SSH key generation and connection test |
| `settings` | GNOME desktop settings (font, scaling, cursor) |

Run a single step: `./run.sh --only editor`  
Skip a step: `MACHINIST_SKIP_SDK=1 ./run.sh`  
Re-install: `MACHINIST_UPGRADE=1 ./run.sh --only editor`

---

## Requirements

| | |
|---|---|
| macOS | 14+ on Apple Silicon or Intel. Xcode Command Line Tools (`xcode-select --install`) |
| Ubuntu | LTS: 22.04 or 24.04, amd64 or arm64 |
| Both | `git` and `curl`, which `install.sh` checks for before doing anything |

CI exercises `ubuntu-24.04` and `macos-15` on every push.
