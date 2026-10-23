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
-- else the project's entry file in a hidden buffer (the user's buffer and window stay as they
-- are). The wait for the server is asynchronous: LspAttach, or give up after 5s and call cb anyway
-- (the modal then says the server is not attached).
function M.with_alder_buf(r, cb)
  local lsp_on = require('alder.config').options.lsp
  local cur = vim.api.nvim_get_current_buf()
  if vim.bo[cur].filetype == 'alder' and (vim.b[cur].alder_lsp or not lsp_on) then return cb(cur) end
  local file = M.entry(r)
  if not file then return vim.notify('alder: no .alder file under app/', vim.log.levels.WARN) end
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = 'hide'
  if vim.bo[buf].filetype ~= 'alder' then vim.bo[buf].filetype = 'alder' end
  if vim.b[buf].alder_lsp or not lsp_on then return cb(buf) end
  local done, timer, au = false, vim.uv.new_timer(), nil
  local function finish()
    if done then return end
    done = true
    timer:stop()
    timer:close()
    if au then pcall(vim.api.nvim_del_autocmd, au) end
    vim.schedule(function() cb(buf) end)
  end
  au = vim.api.nvim_create_autocmd('LspAttach', { buffer = buf, callback = function(ev)
    local c = vim.lsp.get_client_by_id(ev.data.client_id)
    if c and c.name == 'alder' then finish() end
  end })
  timer:start(5000, 0, vim.schedule_wrap(finish))
end

-- generate opens the generator modal from any buffer of a project.
function M.generate()
  local r = M.require_root()
  if r then M.with_alder_buf(r, function(buf) require('alder.modal').open(buf) end) end
end

return M
