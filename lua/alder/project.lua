-- project: what the project-level maps and commands need — the app root from any buffer, and
-- an .alder buffer for the actions that run through the language server.
local root = require('alder.root')

local M = {}

M.NOT_IN_PROJECT = 'alder: not in an Alder project'

-- root is the app root of buf's file, else of the cwd; nil outside a project.
function M.root(buf)
  return root.for_buf(buf or 0) or root.find(vim.fn.getcwd())
end

-- require_root is root, saying so when there is none.
function M.require_root(buf)
  local r = M.root(buf)
  if not r then vim.notify(M.NOT_IN_PROJECT, vim.log.levels.WARN) end
  return r
end

-- entry is the .alder file to open when no buffer of the project is at hand: app/App.alder,
-- else the first .alder file under app/.
function M.entry(r)
  if vim.uv.fs_stat(r .. '/app/App.alder') then return r .. '/app/App.alder' end
  return vim.fs.find(function(name) return name:match('%.alder$') end, { path = r .. '/app', type = 'file', limit = 1 })[1]
end

-- with_alder_buf calls cb(buf) with an .alder buffer attached to the server: the current one,
-- else the project's entry file, opened in the current window.
function M.with_alder_buf(r, cb)
  local cur = vim.api.nvim_get_current_buf()
  if vim.bo[cur].filetype == 'alder' and (vim.b[cur].alder_lsp or not require('alder.config').options.lsp) then
    return cb(cur)
  end
  local file = M.entry(r)
  if not file then return vim.notify('alder: no .alder file under app/', vim.log.levels.WARN) end
  vim.cmd.edit(vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].alder_lsp or not require('alder.config').options.lsp then return cb(buf) end
  vim.wait(5000, function() return vim.b[buf].alder_lsp end, 20)
  cb(buf)
end

-- generate opens the generator modal from any buffer of a project.
function M.generate()
  local r = M.require_root()
  if r then M.with_alder_buf(r, function(buf) require('alder.modal').open(buf) end) end
end

return M
