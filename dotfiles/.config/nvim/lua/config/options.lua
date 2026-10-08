-- Neovim options
-- lua/config/options.lua
--
-- Core editor behaviour. All settings here can be freely changed; the
-- commented-out lines show common alternatives so you can un-comment the
-- ones you prefer.

local opt = vim.opt

-- Remote-plugin providers are optional and unused by this configuration.
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0

-- ─── Leader keys (must be set before any plugin loads) ────────────────────────
vim.g.mapleader = " " -- <Space> as leader
vim.g.maplocalleader = "\\" -- <\> as local leader

-- ─── Appearance ───────────────────────────────────────────────────────────────
opt.termguicolors = true -- enable 24-bit colour (requires a capable terminal)
opt.number = true -- absolute line numbers
opt.relativenumber = true -- relative line numbers alongside absolute
opt.signcolumn = "yes" -- always show sign column (prevents layout jumps)
opt.cursorline = true -- highlight current line
opt.colorcolumn = "100" -- vertical guide at column 100
opt.showmode = false -- mode is shown in status line
opt.laststatus = 3 -- global status line (single bar across splits)

-- ─── Editing ──────────────────────────────────────────────────────────────────
opt.expandtab = true -- spaces instead of tabs
opt.shiftwidth = 4 -- indent by 4 spaces
opt.tabstop = 4 -- visual tab width
opt.softtabstop = 4
opt.smartindent = true -- auto-indent new lines
opt.wrap = false -- no line wrapping
opt.linebreak = true -- wrap at word boundaries (if wrap is enabled)
opt.textwidth = 0 -- no automatic hard wrap

-- ─── Search ───────────────────────────────────────────────────────────────────
opt.ignorecase = true -- case-insensitive search …
opt.smartcase = true -- … unless the query contains uppercase letters
opt.hlsearch = true -- highlight all matches
opt.incsearch = true -- show matches as you type

-- ─── Files & persistence ──────────────────────────────────────────────────────
opt.backup = false -- no backup files
opt.swapfile = false -- no swap files (use undotree instead)
opt.undofile = true -- persistent undo across sessions
opt.undodir = vim.fn.stdpath("state") .. "/undo"

-- ─── Splits ───────────────────────────────────────────────────────────────────
opt.splitbelow = true -- :split opens below
opt.splitright = true -- :vsplit opens to the right

-- ─── Clipboard ────────────────────────────────────────────────────────────────
opt.clipboard = "unnamedplus" -- sync with system clipboard

-- ─── Performance ──────────────────────────────────────────────────────────────
opt.updatetime = 200 -- faster CursorHold events (used by LSP, gitsigns)
opt.timeoutlen = 300 -- time to wait for a mapped sequence to complete

-- ─── Completion ───────────────────────────────────────────────────────────────
opt.completeopt = { "menu", "menuone", "noselect" }

-- ─── Substitution preview ─────────────────────────────────────────────────────
opt.inccommand = "split" -- live preview of :s///, in a split

-- ─── Wildmenu / command-line completion ───────────────────────────────────────
opt.wildmode = "longest:full,full"
opt.pumheight = 10 -- max items in completion menu

-- ─── Whitespace display ───────────────────────────────────────────────────────
opt.list = true
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }

-- ─── Scroll offsets ───────────────────────────────────────────────────────────
opt.scrolloff = 8 -- keep 8 lines above/below cursor
opt.sidescrolloff = 8
