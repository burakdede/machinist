-- UI plugins
-- lua/plugins/ui.lua
--
-- Colour scheme and status line. Both are deliberately the only things here:
-- the terminal (WezTerm) already supplies Dracula, so Neovim matching
-- it is what makes the editor and the shell look like one environment.

return {
	-- ─── Colour scheme ────────────────────────────────────────────────────────
	-- Kept in step with the WezTerm colour_scheme in
	-- dotfiles/.config/wezterm/wezterm.lua. Change both together or the editor
	-- will not match its own terminal.
	{
		"Mofiqul/dracula.nvim",
		name = "dracula",
		lazy = false,
		priority = 1000,
		config = function()
			vim.cmd.colorscheme("dracula")
		end,
	},

	-- ─── Status line ──────────────────────────────────────────────────────────
	-- theme defaults to "auto", which follows the colorscheme above.
	{
		"nvim-lualine/lualine.nvim",
		event = "VeryLazy",
		dependencies = { "nvim-tree/nvim-web-devicons" },
		opts = {},
	},
}
