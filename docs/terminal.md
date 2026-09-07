# Terminal

[← back to README](../README.md)

## Terminal

WezTerm on both platforms, with `disable_default_key_bindings = true` so that
nothing intercepts the Ctrl combinations readline and zsh rely on (Ctrl+R
history search, Ctrl+W kill-word, Ctrl+K kill-line). The bindings are then
declared explicitly, using each platform's native modifier: **Cmd** on macOS,
**Ctrl+Shift** on Linux. Written below as `<mod>`.

| Keys | Action |
|---|---|
| `<mod>` + C / V | Copy / paste |
| `<mod>` + T / W | New tab / close tab |
| `<mod>` + 1..8 | Jump to tab; `<mod>` + 9 jumps to the last |
| Ctrl + Tab | Next tab (Shift for previous) |
| `<mod>` + E / O | Split horizontally / vertically |
| `<mod>` + Shift + H/J/K/L | Move between panes |
| `<mod>` + Z | Zoom pane |
| `<mod>` + K | Clear scrollback |
| `<mod>` + F / X | Search / copy mode |

Because the defaults are off, a binding that is not in `wezterm.lua` does not
exist. If something you expect is missing, add it there rather than assuming
WezTerm provides it.

**Linux uses the native Wayland backend** when the session is Wayland, rather
than falling back to XWayland. XWayland costs fractional scaling and gives
blurry text on HiDPI, which is the common case on modern GNOME. If your
compositor misbehaves, export `WEZTERM_DISABLE_WAYLAND=1` in `~/.zshrc.local`.

## One theme, four tools

The colour scheme is Dracula, and it is set in four places that must
agree or the shell stops looking like a single environment:

| Tool | Where |
|---|---|
| WezTerm | `dotfiles/.config/wezterm/wezterm.lua` (`color_scheme`) |
| Neovim | `dotfiles/.config/nvim/lua/plugins/ui.lua` (`colorscheme`) |
| bat | `dotfiles/.config/bat/config` (`--theme`) |
| delta | `dotfiles/.gitconfig` (`delta.syntax-theme`) |

delta renders through bat, so it takes a bat theme name rather than one of its
own. Dracula ships built into bat, so none of this needs a theme file
or a `bat cache --build`. `./install.sh --verify` fails the "one theme" check
when the four drift apart, which is what happens when you change one and forget
the rest.

`eza` is aliased with `--icons` because the JetBrainsMono Nerd Font is installed
by the system step and is what WezTerm renders with. On a terminal without that
font the icons show as tofu; drop `--icons` from the aliases in `.zshrc` and
`.bashrc` if you use one.

## Terminal input problems

If typing into the terminal produces duplicated characters, stray spaces, or
runaway key repeat, work through these in order. All three have bitten this
setup.

**1. Key repeat set too aggressively (macOS).** This was self-inflicted:
`os-defaults.sh` used to set `KeyRepeat=1` (15ms, ~67 chars/sec) and
`InitialKeyRepeat=10` (150ms), both faster than System Settings can express. A
150ms delay sits *inside* the normal 70-150ms dwell time of a keypress, so
ordinarily-held keys began repeating. Check with:

```bash
defaults read -g KeyRepeat          # want 2  (30ms)
defaults read -g InitialKeyRepeat   # want 15 (225ms)
```

Ubuntu's equivalents are set to match, so both machines type alike:

```bash
gsettings get org.gnome.desktop.peripherals.keyboard delay            # want 225
gsettings get org.gnome.desktop.peripherals.keyboard repeat-interval  # want 30
```

Both take effect only for applications started after the change.

**2. iBus XIM double-processing (Ubuntu).** On X11, `XMODIFIERS=@im=ibus`
makes WezTerm connect to the iBus XIM server, which processes each key event
twice: duplicated and dropped keystrokes. `use_ime = false` alone does not fix
it, because that stops IME *composition*, not the XIM *connection*.

The fix is clearing `XMODIFIERS` before WezTerm starts, and it must cover
**every** launch path, not just the app launcher:

| Launch path | Covered by |
|---|---|
| GNOME launcher / dock | `~/.local/share/applications/*.desktop` override |
| Ctrl+Alt+T, "Open in Terminal" | `/usr/local/bin/wezterm-terminal` wrapper |
| `x-terminal-emulator` | the same wrapper |

Check it is actually clear inside a running WezTerm:

```bash
echo "[$XMODIFIERS]"    # want [] -- if it shows @im=ibus, this path is unpatched
```

**3. Native Wayland backend (Ubuntu).** WezTerm has an open upstream report of
duplicate keystrokes under Wayland. This setup prefers the native backend, for
fractional scaling and crisp HiDPI text. If input misbehaves on Wayland, fall
back to XWayland:

```bash
echo 'export WEZTERM_DISABLE_WAYLAND=1' >> ~/.zshrc.local
```

Note what is deliberately **not** changed: `use_ime` is left at its default
(enabled) on macOS. WezTerm's IME key-repeat bug was fixed in 20220319 and this
setup runs a later build, so disabling it would cost accented and CJK input for
no gain.
