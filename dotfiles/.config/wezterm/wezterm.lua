-- WezTerm configuration
-- https://wezfurlong.org/wezterm/config/files.html
--
-- This file is installed to ~/.config/wezterm/wezterm.lua
-- Fill in your personal customisations below; the defaults listed here
-- are the bare minimum needed for things to work correctly.

local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- Detect platform once; used throughout this file for OS-specific settings.
local is_mac = wezterm.target_triple:find("darwin") ~= nil

-- ─── Shell ────────────────────────────────────────────────────────────────────
-- Use login shell if available; fall back to zsh.
local login_shell = os.getenv("SHELL") or "/bin/zsh"
config.default_prog = { login_shell, "-l" }

-- ─── Terminal colour support ──────────────────────────────────────────────────
-- xterm-256color is the safest cross-platform default -- wezterm-256color
-- terminfo is missing from many systems and causes garbled output.
config.term = "xterm-256color"

-- ─── Linux-specific settings ─────────────────────────────────────────────────
if not is_mac then
	-- Kitty keyboard protocol causes key-repeat/input jitter on some Linux/X11
	-- setups. (This is also WezTerm's own default; set explicitly so a future
	-- default change cannot reintroduce the problem.)
	config.enable_kitty_keyboard = false

	-- Do not let WezTerm compose input through an IME.
	--
	-- On X11 the iBus XIM server double-processes key events, which shows up as
	-- duplicated and dropped keystrokes. The primary fix is clearing XMODIFIERS
	-- before WezTerm starts -- linux/terminal/terminal.sh installs a launcher
	-- wrapper and a .desktop override that do exactly that -- because this
	-- setting alone stops IME composition but not the XIM connection itself.
	--
	-- Belt and braces: this covers the case where WezTerm is started some other
	-- way and XMODIFIERS leaks through.
	--
	-- Flip this back to true if you need IME composition (CJK input, dead keys
	-- for accented characters). It is off because this setup assumes a US
	-- layout, where nothing is composed.
	config.use_ime = false

	-- Wayland vs X11.
	--
	-- Running under XWayland costs fractional scaling and gives blurry text on
	-- HiDPI displays, which is the common case on a modern GNOME desktop
	-- (Wayland has been the Ubuntu default since 21.04). So prefer the native
	-- Wayland backend whenever the session is actually Wayland.
	--
	-- If your compositor misbehaves, force X11 by exporting
	-- WEZTERM_DISABLE_WAYLAND=1 in ~/.zshrc.local.
	local wayland_session = os.getenv("WAYLAND_DISPLAY") ~= nil
	local wayland_opt_out = os.getenv("WEZTERM_DISABLE_WAYLAND") ~= nil
	config.enable_wayland = wayland_session and not wayland_opt_out
end

-- ─── Scrollback ───────────────────────────────────────────────────────────────
config.scrollback_lines = 10000

-- ─── Tab bar ──────────────────────────────────────────────────────────────────
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false -- retro tab bar; styled via colors below
config.tab_bar_at_bottom = true
config.tab_max_width = 32

-- Tab title: explicit title > process (if not shell) > cwd basename > "?"
-- Unseen output in inactive tabs is marked with a dot prefix.
local SHELLS = { zsh = true, bash = true, sh = true, fish = true }

local function basename(path)
	return (path or ""):match("([^/\\]+)[/\\]?$") or path or ""
end

wezterm.on("format-tab-title", function(tab, _tabs, _panes, _config, _hover, max_width)
	local pane = tab.active_pane

	-- 1. Explicit title set via `wezterm cli set-tab-title` or OSC 0/2
	local title = (tab.tab_title and tab.tab_title ~= "") and tab.tab_title or nil

	-- 2. Foreground process, if it is not a bare shell
	if not title then
		local proc = basename(pane.foreground_process_name or "")
		if proc ~= "" and not SHELLS[proc] then
			title = proc
		end
	end

	-- 3. Current working directory basename
	if not title then
		local cwd_obj = pane.current_working_dir
		if cwd_obj then
			local path = type(cwd_obj) == "table" and cwd_obj.file_path or tostring(cwd_obj)
			local dir = basename(path)
			if dir ~= "" then
				title = dir
			end
		end
	end

	title = title or "?"

	-- Truncate
	if #title > max_width - 4 then
		title = title:sub(1, max_width - 5) .. "…"
	end

	local prefix = (not tab.is_active and pane.has_unseen_output) and "● " or ""
	local zoomed = pane.is_zoomed and " ⬡" or ""
	return string.format(" %s%d: %s%s ", prefix, tab.tab_index + 1, title, zoomed)
end)

-- ─── Font ─────────────────────────────────────────────────────────────────────
-- Prefer JetBrainsMono Nerd Font (installed via brew cask / system step).
-- Falls back to common system monospaced fonts so WezTerm starts cleanly on a
-- machine where the Nerd Font hasn't been installed yet.
config.font = wezterm.font_with_fallback({
	"JetBrainsMono Nerd Font",
	is_mac and "Menlo" or "DejaVu Sans Mono",
	"monospace",
})
config.font_size = 15.0

-- Font rendering quality.
-- freetype_* settings apply on Linux only; macOS uses CoreText and ignores them.
-- "Normal" hinting gives crisp baselines on non-HiDPI displays (switch to
-- "Light" if text feels too heavy). "HorizontalLcd" enables RGB subpixel
-- rendering for sharper edges on LCD panels.
if not is_mac then
	config.freetype_load_target = "Normal"
	config.freetype_render_target = "HorizontalLcd"
end

-- ─── Key bindings ─────────────────────────────────────────────────────────────
-- WezTerm's defaults intercept many Ctrl+letter combos that readline/zsh rely
-- on (Ctrl+R history search, Ctrl+W kill-word, Ctrl+K kill-line, etc.).
-- Disable conflicting defaults and use platform-native modifier keys:
--   macOS  → CMD        (Cmd+C/V/T/W -- standard Mac conventions)
--   Linux  → CTRL+SHIFT (Ctrl+Shift+C/V/T/W -- standard Linux conventions)
config.disable_default_key_bindings = true

local act = wezterm.action
local mod = is_mac and "SUPER" or "SHIFT|CTRL"
-- Pane navigation adds SHIFT on macOS so <mod>+k stays free for clear-scrollback.
local pane_mod = is_mac and "SUPER|SHIFT" or "SHIFT|CTRL|ALT"

config.keys = {
	-- ── Clipboard ──────────────────────────────────────────────────────────
	{ key = "c", mods = mod, action = act.CopyTo("Clipboard") },
	{ key = "v", mods = mod, action = act.PasteFrom("Clipboard") },

	-- ── Tabs ───────────────────────────────────────────────────────────────
	{ key = "t", mods = mod, action = act.SpawnTab("CurrentPaneDomain") },
	{ key = "w", mods = mod, action = act.CloseCurrentTab({ confirm = true }) },
	{ key = "Tab", mods = "CTRL", action = act.ActivateTabRelative(1) },
	{ key = "Tab", mods = "SHIFT|CTRL", action = act.ActivateTabRelative(-1) },

	-- ── Panes ──────────────────────────────────────────────────────────────
	{ key = "e", mods = mod, action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
	{ key = "o", mods = mod, action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
	{ key = "z", mods = mod, action = act.TogglePaneZoomState },

	-- ── Font size ──────────────────────────────────────────────────────────
	{ key = "=", mods = is_mac and "SUPER" or "CTRL", action = act.IncreaseFontSize },
	{ key = "-", mods = is_mac and "SUPER" or "CTRL", action = act.DecreaseFontSize },
	{ key = "0", mods = is_mac and "SUPER" or "CTRL", action = act.ResetFontSize },

	-- ── Window ─────────────────────────────────────────────────────────────
	{ key = "n", mods = mod, action = act.SpawnWindow },
	{ key = "F11", action = act.ToggleFullScreen },

	-- ── Copy mode (vim-like keyboard text selection) ───────────────────────
	{ key = "x", mods = mod, action = act.ActivateCopyMode },

	-- ── Search ─────────────────────────────────────────────────────────────
	{ key = "f", mods = mod, action = act.Search("CurrentSelectionOrEmptyString") },

	-- ── Scrollback ─────────────────────────────────────────────────────────
	{ key = "PageUp", mods = "SHIFT", action = act.ScrollByPage(-1) },
	{ key = "PageDown", mods = "SHIFT", action = act.ScrollByPage(1) },

	-- ── Clear scrollback ───────────────────────────────────────────────────
	-- Disabling the default bindings above removed this; it is muscle memory
	-- on macOS and worth keeping on both platforms.
	{ key = "k", mods = mod, action = act.ClearScrollback("ScrollbackAndViewport") },

	-- ── Pane navigation ────────────────────────────────────────────────────
	-- hjkl, as in vim and tmux. On SHIFT so that plain <mod>+k stays free for
	-- clear-scrollback above, keeping all four directions symmetric.
	{ key = "h", mods = pane_mod, action = act.ActivatePaneDirection("Left") },
	{ key = "j", mods = pane_mod, action = act.ActivatePaneDirection("Down") },
	{ key = "k", mods = pane_mod, action = act.ActivatePaneDirection("Up") },
	{ key = "l", mods = pane_mod, action = act.ActivatePaneDirection("Right") },
}

-- ── Jump straight to a tab ────────────────────────────────────────────────
-- Also lost to disable_default_key_bindings. Cmd+1..9 on macOS,
-- Ctrl+Shift+1..9 on Linux; 9 always means "last tab", as in browsers.
for i = 1, 8 do
	table.insert(config.keys, {
		key = tostring(i),
		mods = mod,
		action = act.ActivateTab(i - 1),
	})
end
table.insert(config.keys, { key = "9", mods = mod, action = act.ActivateTab(-1) })

-- ─── Mouse bindings ──────────────────────────────────────────────────────────
config.mouse_bindings = {
	-- Right-click pastes from clipboard; if text is selected, right-click copies instead.
	{
		event = { Down = { streak = 1, button = "Right" } },
		mods = "NONE",
		action = wezterm.action_callback(function(window, pane)
			local has_selection = window:get_selection_text_for_pane(pane) ~= ""
			if has_selection then
				window:perform_action(act.CopyTo("ClipboardAndPrimarySelection"), pane)
				window:perform_action(act.ClearSelection, pane)
			else
				window:perform_action(act.PasteFrom("Clipboard"), pane)
			end
		end),
	},
}

-- ─── Colour scheme ───────────────────────────────────────────────────────────
config.color_scheme = "Dracula"

-- ─── Transparency & blur ─────────────────────────────────────────────────────
-- window_background_opacity: 1.0 = opaque, 0.0 = fully transparent.
-- macos_window_background_blur blurs the content behind the window (macOS only).
-- On Linux/X11 (no compositor blur API) transparency shows the desktop beneath.
-- Keep the terminal opaque so syntax colors retain their contrast against the
-- Dracula background, especially when a bright desktop image is behind it.
config.window_background_opacity = 1.0
config.macos_window_background_blur = 50 -- macOS only; no-op on Linux

-- ─── Window Decoration ───────────────────────────────────────────────────────────
config.window_decorations = "RESIZE"

-- ─── Tab bar colours (Dracula palette) ───────────────────────────────────────

config.colors = {
	tab_bar = {
		background = "#191a21",
		active_tab = {
			bg_color = "#bd93f9",
			fg_color = "#282a36",
			intensity = "Bold",
		},
		inactive_tab = {
			bg_color = "#282a36",
			fg_color = "#f8f8f2",
		},
		inactive_tab_hover = {
			bg_color = "#6272a4",
			fg_color = "#f8f8f2",
		},
		new_tab = {
			bg_color = "#191a21",
			fg_color = "#6272a4",
		},
		new_tab_hover = {
			bg_color = "#6272a4",
			fg_color = "#f8f8f2",
		},
	},
}

-- ─── Your customisations below ───────────────────────────────────────────────
-- Window padding:  config.window_padding = { left = 8, right = 8, top = 6, bottom = 6 }

return config
