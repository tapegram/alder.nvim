local config = require('alder.config')
local root = require('alder.root')

local M = {}
local leaving = false
vim.api.nvim_create_autocmd('VimLeavePre', { callback = function() leaving = true end })

-- A buffer that detaches from the alder client is no longer covered by the server.
vim.api.nvim_create_autocmd('LspDetach', {
  callback = function(ev)
    local c = vim.lsp.get_client_by_id(ev.data.client_id)
    if c and c.name == 'alder' and vim.api.nvim_buf_is_valid(ev.buf) then vim.b[ev.buf].alder_lsp = nil end
  end,
})

function M.start(buf)
  if not config.options.lsp then return end
  local r = root.for_buf(buf)
  if not r then return end
  vim.lsp.start({
    name = 'alder',
    cmd = { config.options.cmd, 'lsp' },
    root_dir = r,
    on_attach = function(_, b) vim.b[b].alder_lsp = true end,
    on_exit = function(code, signal)
      vim.schedule(function()
        if not leaving and (code ~= 0 or signal ~= 0) then
          vim.notify('alder lsp stopped — :checkhealth alder', vim.log.levels.WARN)
        end
      end)
    end,
  }, { bufnr = buf, reuse_client = function(c, conf) return c.name == 'alder' and c.root_dir == conf.root_dir end })
end

function M.client(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = 'alder' })[1]
end

-- request sends method to buf's server. cb gets the result; an error is shown once with the
-- server's own message, and a cancelled request (-32800) shows nothing.
function M.request(buf, method, params, cb)
  local c = M.client(buf)
  if not c then
    vim.notify('alder: the language server is not attached (:checkhealth alder)', vim.log.levels.WARN)
    return
  end
  c:request(method, params, function(err, result)
    if err then
      if err.code ~= -32800 then vim.notify(err.message, vim.log.levels.ERROR) end
      return
    end
    cb(result)
  end, buf)
end

function M.status()
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = 'alder' })) do
    table.insert(out, { root = c.root_dir, running = not c:is_stopped() })
  end
  return out
end

return M
