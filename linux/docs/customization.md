# Customization

## Philosophy

This repository is usable as-is, but it is also meant to be easy to adapt. Customization should mostly happen in manifests, version pins, and optional modules rather than by rewriting orchestration logic.

## Skip Flags

Any major install step can be skipped with `MACHINIST_SKIP_<STEP>=1`.

Example:

```bash
MACHINIST_SKIP_DOCKER=1 MACHINIST_SKIP_CHROME=1 ./run.sh
```

Available skip flags:

| Variable | Skips |
|---|---|
| `MACHINIST_SKIP_DOCKER` | Docker CLI and Compose plugin |
| `MACHINIST_SKIP_CLOUD_CLIS` | The AWS and Google Cloud CLIs |
| `MACHINIST_SKIP_CHROME` | Google Chrome |
| `MACHINIST_SKIP_GITHUB_RELEASE_TOOLS` | GitHub-release binaries such as `yq`, `eza`, `sd`, `scc` |
| `MACHINIST_SKIP_UV` | `uv` and `uv`-managed tools |
| `MACHINIST_SKIP_CLAUDE` | Claude Code |
| `MACHINIST_SKIP_NPM_TOOLS` | npm CLIs and MCP packages |
| `MACHINIST_SKIP_GO` | Go toolchain via `mise` |
| `MACHINIST_SKIP_PYTHON` | Python toolchain via `mise` |
| `MACHINIST_SKIP_RUST` | Rust toolchain via `rustup` |
| `MACHINIST_SKIP_IAC_TOOLS` | IaC tooling via `mise` (`terraform`, `tflint`, `terragrunt`, `terraform-docs`) |
| `MACHINIST_SKIP_UFW` | firewall setup |
| `MACHINIST_SKIP_WEZTERM` | terminal installation in verification and smoke flows |
| `MACHINIST_SKIP_NEOVIM` | editor installation in verification and smoke flows |
| `MACHINIST_SKIP_FONTS` | Nerd Fonts installation |

## Optional Modules

These run by default, but you can skip them when needed:

- `git`: GitHub SSH setup (`--skip-git`)
- `settings`: GNOME desktop preferences (`--skip-settings`)

They are interactive/workstation-specific, so skip flags are provided for unattended runs.

## HiDPI Display Tuning (GNOME)

The settings step now applies HiDPI-friendly defaults:

- enables fractional scaling support
- sets text scale to `1.15`
- sets cursor size to `32`
- sets font rendering defaults: `rgba` antialiasing, `slight` hinting, `rgb` subpixel order
- sets GNOME monospace font to `JetBrainsMono Nerd Font 12`

Override during settings run:

```bash
MACHINIST_TEXT_SCALE=1.20 MACHINIST_CURSOR_SIZE=36 ./run.sh
```

Panel-specific font tuning:

```bash
MACHINIST_FONT_RGBA_ORDER=rgb \
MACHINIST_FONT_ANTIALIASING=rgba \
MACHINIST_FONT_HINTING=slight \
MACHINIST_MONOSPACE_FONT="JetBrainsMono Nerd Font 12" \
./run.sh --include-settings
./run.sh
```

Notes:

- Use `MACHINIST_FONT_RGBA_ORDER=bgr` only if your panel subpixel layout is BGR.
- On high-DPI screens, `slight` hinting is usually cleaner than `full`.

## Wallpapers (Desktop + Login Screen)

The settings step can configure both:

- Desktop wallpaper (`org.gnome.desktop.background`)
- Login screen wallpaper (GDM dconf profile)

Default image locations (relative to repo root):

- `assets/wallpapers/desktop.jpg`
- `assets/wallpapers/login.jpg`

Override with environment variables:

```bash
MACHINIST_DESKTOP_WALLPAPER_PATH=/absolute/path/my-desktop.jpg \
MACHINIST_LOGIN_WALLPAPER_PATH=/absolute/path/my-login.jpg \
./run.sh --include-settings
```

Notes:

- Relative paths are resolved from the repository root.
- Login wallpaper setup writes system files under `/etc/dconf` and `/usr/share/backgrounds`, so it requires `sudo`.
- If either image is missing, setup logs a warning and continues.

## Manifests

Most package decisions live in text manifests. Which directory a manifest
lives in tells you its scope.

**Shared with macOS** (repo root, one list drives both machines):

- `packages/sdkman.txt` -- JVM candidates
- `packages/uv-tools.txt` -- Python CLI tools
- `packages/npm-packages.txt` -- Node CLI tools
- `dotfiles/.config/mise/config.toml` -- language runtimes

**Ubuntu-specific** (this directory, no macOS equivalent):

- `system/apt-packages.txt`
- `system/github-tools.txt` -- upstream release binaries not packaged in APT

If you want to tailor the machine, start there first. Adding a cross-platform
CLI tool to an Ubuntu-only list is the usual way the two machines drift apart.

## Version Pins

Pins are shared with macOS and split by who installs the tool. There is no
longer a `linux/versions.txt`.

**mise-managed** -- [`dotfiles/.config/mise/config.toml`](../../dotfiles/.config/mise/config.toml):

- Python, Node, Go
- Terraform, TFLint, Terragrunt, terraform-docs

**Everything else** -- [`packages/versions.txt`](../../packages/versions.txt):

- `mise` itself
- Rust toolchain
- Neovim
- Nerd Fonts

WezTerm is not pinned; the terminal step resolves the latest release and
prefers the `.deb` matching this Ubuntu version.

Upgrade flow:

1. Change the version in whichever of the two files owns that tool.
2. Rerun the relevant step or `./run.sh`.
3. Verify with `./run.sh --verify` and `bash scripts/test.sh`.
4. Commit only after the new pin is stable.

Never run `mise use --global` to bump a runtime. It rewrites
`~/.config/mise/config.toml`, which is a symlink into this repo, so it edits
tracked config as a side effect of a bootstrap run. Edit the file directly.

## Dotfiles And Personal Preferences

The repo includes personal dotfiles, but they are installed through a dedicated step so they are easy to replace or fork.

Practical ways to adapt the repo:

- swap the contents of `dotfiles/` with your own
- keep `system/` mostly generic and move personal preferences into `dotfiles/`, `git/`, and `utils/settings.sh`
- leave `run.sh` orchestration alone unless the execution order itself needs to change

## Zsh Profile Selection

The shell step supports two fast profiles:

- `antidote-p10k` (default)
- `zsh4humans`

Choose profile during bootstrap:

```bash
MACHINIST_ZSH_PROFILE=antidote-p10k ./run.sh --only shell
MACHINIST_ZSH_PROFILE=zsh4humans ./run.sh --only shell
```

Profile can also be overridden at runtime in `~/.zshrc` via `ZSH_PROFILE`.

## WezTerm + tmux + Neovim Integration

The default dotfiles now align these tools for a consistent workflow:

- WezTerm starts your login shell (`$SHELL`, fallback `/bin/zsh`)
- zsh can auto-attach to tmux session `main` when enabled
- tmux uses zsh login shell and preserves working directory on splits
- Neovim and tmux share pane navigation via `Ctrl-h/j/k/l`

Useful toggles:

```bash
# Enable tmux auto-attach for this machine
echo 'export ZSH_TMUX_AUTO_ATTACH=1' >> ~/.zshrc.local
```

## Upgrade Behavior

Some installs are intentionally skipped if already present. To force reinstall or refresh during a maintenance pass:

```bash
MACHINIST_UPGRADE=1 ./run.sh --only system
```

Use this deliberately. The default behavior favors stability over constant upgrades.

The system step does not upgrade or autoremove unrelated host packages by
default. To request that broader maintenance pass explicitly:

```bash
MACHINIST_SYSTEM_UPGRADE=1 ./run.sh --only system
```
