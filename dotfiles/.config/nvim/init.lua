-- Neovim configuration entry point
-- ~/.config/nvim/init.lua
--
-- Plugin manager: lazy.nvim (https://github.com/folke/lazy.nvim)
-- On the very first launch, lazy.nvim bootstraps itself automatically.
--
-- Layout:
--   lua/config/options.lua   -- vim options (set …)
--   lua/config/keymaps.lua   -- key mappings
--   lua/config/autocmds.lua  -- autocommands
--   lua/plugins/             -- one file per plugin group

-- ─── Bootstrap lazy.nvim ──────────────────────────────────────────────────────
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

-- ─── Options (must load before plugins) ──────────────────────────────────────
require("config.options")

-- ─── Plugins ──────────────────────────────────────────────────────────────────
-- lazy.nvim auto-discovers spec files inside lua/plugins/
require("lazy").setup("plugins", {
	defaults = { lazy = true },
	install = { colorscheme = { "habamax" } },
	-- This setup has no plugins that use LuaRocks packages.
	rocks = { enabled = false },
	checker = { enabled = false }, -- set true to auto-check for plugin updates
	change_detection = { notify = false },
	performance = {
		rtp = {
			disabled_plugins = {
				"gzip",
				"tarPlugin",
				"tohtml",
				"tutor",
				"zipPlugin",
			},
		},
	},
})

-- ─── Keymaps & autocommands (load after plugins) ─────────────────────────────
require("config.keymaps")
require("config.autocmds")
