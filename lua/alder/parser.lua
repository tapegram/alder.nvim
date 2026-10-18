local M = {}

-- install_info is nvim-treesitter main's description of the alder parser. `queries` is relative
-- to the repository root, also when `path` points at a local checkout (install.lua), so `path`
-- is the alder checkout itself, not its tree-sitter-alder/ directory.
function M.install_info()
  local o = require('alder.config').options
  local info = { location = 'tree-sitter-alder', queries = 'tree-sitter-alder/queries/neovim' }
  if o.path then
    info.path = vim.fs.normalize(o.path)
  else
    info.url = 'https://github.com/tapegram/alder'
    info.revision = o.revision
  end
  return info
end

-- register adds alder to nvim-treesitter's parser table. It runs at startup and on every
-- `User TSUpdate` (nvim-treesitter reloads its table before installing).
function M.register()
  local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
  if not ok then return end
  parsers.alder = { install_info = M.install_info() }
end

return M
