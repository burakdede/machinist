# Versions and packages

[← back to README](../README.md)

## Versions

Every version is pinned in exactly one place, shared by both platforms.

| Pinned in | Covers |
|---|---|
| [`dotfiles/.config/mise/config.toml`](../dotfiles/.config/mise/config.toml) | Everything mise manages: Python, Node, Go, Terraform, tflint, Terragrunt, terraform-docs |
| [`packages/versions.txt`](../packages/versions.txt) | Everything mise does not: Neovim, mise itself, Rust toolchain, Nerd Fonts |

There are no per-platform `versions.txt` files. Both machines resolve the same
pins, so `node --version` gives the same answer on each.

**Do not run `mise use --global`.** It rewrites `~/.config/mise/config.toml`,
which is a symlink into this repo, so it would silently edit tracked config.
The setup scripts run `mise install`, which only reads. To change a runtime
version, edit `dotfiles/.config/mise/config.toml` and commit it.

Per-project overrides still work normally through a project's own `.mise.toml`
or `.tool-versions`.

### mise trust

mise discovers config by walking **up from the current directory**, looking for
`.config/mise/config.toml` in each ancestor. Because our copy lives at
`<repo>/dotfiles/.config/mise/config.toml`, the moment you `cd` into the
dotfiles directory to edit something -- the workflow this repo is built around
-- mise finds it as a *project* config rather than the global one.

Project configs need explicit trust, while `~/.config/mise/config.toml` is
trusted implicitly. Untrusted, every mise command run from inside the repo
fails with:

```
mise ERROR Config files in .../dotfiles/.config/mise/config.toml are not trusted.
```

The `dotfiles` step grants that trust for you. Trust is recorded per machine
under `~/.local/state/mise/trusted-configs`, so it cannot be committed and has
to be granted once on each machine. If you ever hit the error, either re-run
`./run.sh --only dotfiles` or do it directly:

```bash
mise trust <clone>/dotfiles/.config/mise/config.toml
```

`--verify` checks this and fails if the config is untrusted.

## Adding a new tool

**Homebrew (macOS):** add to [`mac/Brewfile`](../mac/Brewfile), then `brew bundle`.

**APT (Linux):** add to [`linux/system/apt-packages.txt`](../linux/system/apt-packages.txt), then `sudo apt-get install <pkg>`.

**GitHub release binary (Linux):** add a line to [`linux/system/github-tools.txt`](../linux/system/github-tools.txt) in the format `command|owner/repo|asset_regex|mode|binary`. Supported modes are `raw`, `tar.gz`, `tar.xz`, and `gz`.

**Vendor installer (Linux):** add a function to [`linux/system/system.sh`](../linux/system/system.sh) and a skip block in `main`. Use this only when no GitHub release or APT package exists.

**npm (both):** add to [`packages/npm-packages.txt`](../packages/npm-packages.txt) in the format `package[|command]`. Give the command when the executable does not share the package name, as with `@ast-grep/cli` installing `ast-grep`.

**Both platforms:** prefer a shared manifest so the two machines cannot drift.

| Kind of tool | Add it to |
|---|---|
| Language runtime or IaC tool | [`mise/config.toml`](../dotfiles/.config/mise/config.toml) |
| Python CLI | [`uv-tools.txt`](../packages/uv-tools.txt) |
| Node CLI | [`npm-packages.txt`](../packages/npm-packages.txt) |
| Browser for visual checks | `playwright`, in the same npm manifest |
| JVM SDK | [`sdkman.txt`](../packages/sdkman.txt) |
| Version pin for something mise does not manage | [`versions.txt`](../packages/versions.txt) |

Only reach for `mac/Brewfile` or `linux/system/apt-packages.txt` when the tool
genuinely has no cross-platform installer, and then add it to **both**. Adding a
cross-platform tool to one OS list only is the usual way the machines diverge.
