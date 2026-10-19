-- tests/minimal.lua: a bare Neovim with nvim-treesitter (main) and this plugin.
-- NVIM_TS points at an nvim-treesitter checkout (default: the lazy.nvim one), ALDER_REPO at an
-- alder checkout whose tree-sitter-alder/ is installed as the parser (default ~/projects/alder).
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local ts = os.getenv('NVIM_TS') or vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
-- NVIM_NUI points at a nui.nvim checkout (default: the lazy.nvim one); the generator modal needs it
local nui = os.getenv('NVIM_NUI') or vim.fn.expand('~/.local/share/nvim/lazy/nui.nvim')
local data = here .. '/.tests'
-- Neovim's bundled parsers (markdown for :AlderExplain's float) live outside $VIMRUNTIME
local bundled = vim.api.nvim_get_runtime_file('parser/markdown.so', false)[1]
vim.opt.rtp = { here, ts, nui, vim.env.VIMRUNTIME, bundled and vim.fn.fnamemodify(bundled, ':h:h') or nil }
vim.opt.packpath = { vim.env.VIMRUNTIME } -- where matchit lives
vim.g.loaded_netrwPlugin = 1 -- netrw's plugin needs a packpath
vim.opt.swapfile = false
vim.cmd('filetype plugin indent on')
-- the dir must exist when it joins the runtimepath, or Neovim never scans it for the parser
vim.fn.mkdir(data .. '/site', 'p')
require('nvim-treesitter').setup({ install_dir = data .. '/site' })
vim.cmd('runtime plugin/matchit.vim') -- -l skips plugin loading; a normal Neovim loads it itself
vim.cmd('runtime plugin/alder.lua')
require('alder').setup({ path = os.getenv('ALDER_REPO') or vim.fn.expand('~/projects/alder') })
