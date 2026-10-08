# Shell environment

[← back to README](../README.md)

## Shared dotfiles

Everything in `dotfiles/` is cross-platform. OS-specific paths are handled inside each config file at runtime:

- **`.zshenv`** -- XDG dirs, `$EDITOR`, and user PATH entries; sourced by every zsh process
- **`.zprofile`** -- Homebrew init on macOS, mise shims; sourced by login shells only
- **`.zshrc`** -- fzf key-bindings source differs by OS (detected at runtime)
- **`.bashrc` / `.bash_profile`** -- the same environment for bash; see below
- **`wezterm.lua`** -- uses `wezterm.target_triple:find("darwin")` to switch modifier keys
- **`tmux.conf`** -- fully cross-platform
- **`nvim/`** -- fully cross-platform

### Shell environment: what this setup decides for you

Two deliberate choices in the zsh files that are easy to get wrong:

**Homebrew is initialised in `.zprofile`, not `.zshenv`.** zsh sources files in the
order `/etc/zshenv` → `~/.zshenv` → `/etc/zprofile` → `~/.zprofile` → `~/.zshrc`.
macOS ships an `/etc/zprofile` that runs `/usr/libexec/path_helper`, which rebuilds
PATH and hoists `/usr/bin` to the front. A `brew shellenv` in `~/.zshenv` runs before
that and is silently undone, leaving you on Apple's `git`, `curl` and `jq` even though
the Homebrew ones are installed. Running it from `~/.zprofile` (after `path_helper`)
is what actually makes Homebrew win. If you add PATH entries of your own and expect
them to beat the system ones on macOS, put them in `.zprofile` too.

**`typeset -U path PATH` is set in `.zshenv`.** This setup nests login shells on
purpose (WezTerm spawns `$SHELL -l`, tmux spawns `$SHELL -l` again per pane), so
without de-duplication PATH grows at every nesting level. macOS hides this via
`path_helper`; Ubuntu does not, so it is made explicit for both.

**The completion dump is cached for 24 hours.** `compinit` rescans `fpath` and
rewrites `~/.cache/zsh/.zcompdump-<version>` on every shell start by default,
which is the most expensive thing in `.zshrc`. It now does the full scan at most
once a day and uses `compinit -C` otherwise. If you install a tool that ships
new shell completions and they do not show up, drop the cache:

```bash
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/.zcompdump-*
```

Plugins are loaded **before** `compinit`, because `compinit` only sees the
`fpath` it is given at call time. If you add a plugin that ships completions,
it must go in `.zsh_plugins.txt`, not below the completion block.

**`LC_ALL` is not set, only `LANG`.** `LC_ALL` overrides every `LC_*` category
at once and outranks `LANG`, so setting it discards the region you chose in
System Settings or `localectl`. An `en_GB` machine would still get US date and
number formats. Pin it per command when you need to: `LC_ALL=C sort`.

**`pbcopy` / `pbpaste` work on both machines.** They are macOS built-ins; on
Linux they are aliased to `wl-copy`/`wl-paste` under Wayland or `xclip` under
X11, so the same commands and the same scripts work either side.

**fzf is backed by `fd`** via `FZF_DEFAULT_COMMAND`, so it honours `.gitignore`
and skips `.git` instead of shelling out to `find` and walking `node_modules`.
Shell integration comes from `fzf --zsh` where available (0.48+), falling back
to the packaged scripts on older Ubuntu builds.

**`bat` is not aliased over `cat`,** deliberately: it adds decorations that
break piping and copy-paste. It is wired in only where it is unambiguously
better, as `MANPAGER` for syntax-highlighted man pages and as the preview
window for fzf's Ctrl-T.

**`cd` is zoxide, not the builtin.** Both shells initialise zoxide with
`--cmd cd`, which replaces `cd` outright rather than adding a `z` command next
to it. That is deliberate: a second command only helps once you remember to
reach for it, and `cd` is the most-typed command on this machine.

Nothing about the old behaviour is lost. Real paths, `cd -`, `cd ..` and a bare
`cd` all work exactly as before; zoxide only adds a fallback for when the
argument is not a path, matching it against directories you have already
visited. So `cd machinist` from anywhere lands in the repo. `cdi` opens an
interactive picker, which uses `fzf` when it is present.

The init line sits **below** `compinit` in `.zshrc` and below the
`bash_completion` block in `.bashrc`. zoxide attaches its completions to the
existing completion system, and they are silently dropped if it has not been
initialised yet. It is also below `direnv`, so jumping into a directory still
fires direnv's hook.

**`delta` is the git pager,** configured in `.gitconfig`. The setting is
guarded with a `command -v` fallback to `less`, because git treats a missing
pager as a fatal error and this file is symlinked on machines where the system
step may not have run yet.

**bash is kept in step with zsh.** zsh is the daily driver, but bash still gets
used: scripts, rescue shells, remote boxes without zsh. It previously had *no*
config in this repo, and the consequence was not cosmetic -- mise was never
activated there, so `node` resolved to Homebrew's v26 in bash while zsh
correctly used the pinned 24.18.1. A script would behave differently depending
on which shell ran it.

`dotfiles/.bashrc` now mirrors `.zshrc` on the things that matter: PATH (with a
hand-rolled de-duplicator, since bash has no `typeset -U`), mise activation,
the SDKMAN environment, aliases, fzf, bat, and clipboard parity.
`.bash_profile` just sources it, so there is one file rather than two that
drift.

It is deliberately *not* a second daily driver: no plugin framework, and a
small hand-written prompt rather than a second prompt framework, since
powerlevel10k is zsh-only. `--verify` checks that both shells resolve `node`
identically and that mise is active in bash.

### Startup speed

Startup is treated as a feature, and `--verify` fails if it regresses.

| | |
|---|---|
| zsh, typical | **~120ms** |
| bash, typical | ~160ms |
| zsh, first ever run | ~420ms (builds the completion dump once) |

Best of ten `time zsh -lic exit` on an idle machine. Treat them as an order of
magnitude, not a budget: the same config measures 30-45ms of first-prompt lag
under `zsh-bench` depending only on how busy the machine is, so a difference
under ~10ms is noise. CI enforces a deliberately loose 400ms.

Three things get it there:

**Shell integrations are cached.** `brew shellenv`, `mise activate`, `fzf --zsh`,
`direnv hook` and `zoxide init` each print shell code you have to `eval`. That is
five fork+execs on every single shell, and together they were ~50ms of a ~90ms
startup -- pure repeated work, since the output only changes when the tool does.
`_evalcache` (in `.zshenv`, mirrored in `.bashrc`) runs each generator once,
stores the result under `$XDG_CACHE_HOME/zsh/init/`, byte-compiles it, and
sources that instead. It regenerates automatically when the generating binary
is newer than its cache, so upgrades are picked up without you thinking about
it.

**The completion dump is rebuilt in the background.** Rescanning `fpath` costs
~450ms. Doing that synchronously, even once a day, is a visible stall. So the
cached dump is always loaded instantly with `compinit -C`, and if it has gone
stale the rebuild is detached with `&!` for the *next* shell. The only cost is
that a newly installed completion appears one shell launch later. Stale-dump
startup went from 470ms to 60ms.

**Config files are byte-compiled.** `.zshrc`, `.zshenv`, `.zprofile`,
`.p10k.zsh` and the plugin bundle each get a `.zwc` that zsh loads instead of
re-parsing the source. Recompiled automatically whenever the source changes,
and gitignored.

To force everything to rebuild:

```bash
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/init "${XDG_CACHE_HOME:-$HOME/.cache}"/bash/init
rm -f  "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/.zcompdump-* <clone>/dotfiles/*.zwc
```

One case is genuinely slow and is not ours: the first shell after a `mise`
upgrade takes ~400ms, because mise revalidates its own internal cache when its
binary changes. It happens once per upgrade.

**SDKMAN is loaded lazily.** `sdkman-init.sh` loops over every installed
candidate in shell to build PATH, which costs ~90ms per shell with ten
candidates -- around 40% of total startup. `.zshrc` instead globs
`~/.sdkman/candidates/*/current/bin` onto PATH directly and sets `JAVA_HOME`,
so `java`, `kotlin`, `scala` and friends are available immediately, and defers
the real init until the first time you actually run `sdk`. The `sdk` stub
replaces itself on first call, so everything (`sdk list`, `sdk use`, `sdk env`)
behaves normally.

`zprof` on the current config puts the remaining time in two places: mise's
`_mise_hook` (~25ms, a fork of the mise binary on the first prompt) and
`compinit` (~22ms). Both are the price of the features, not overhead this repo
added.

### Editing configs

```bash
# edit from anywhere
$EDITOR <clone>/dotfiles/.config/nvim/init.lua

# commit and push -- both machines pick it up on next git pull
cd <clone>
git commit -am "nvim: add keymap for telescope"
git push
```

### Pulling changes on the other machine

```bash
cd <clone>
git pull
# dotfiles are symlinks -- changes are live immediately, no re-run needed
# unless you added a new dotfile that requires a new symlink:
./mac/run.sh --only dotfiles   # or ./linux/run.sh --only dotfiles
```
