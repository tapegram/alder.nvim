local M = {}

M.defaults = {
  cmd = 'alder', -- the alder binary
  check_on_save = true, -- run `alder check` after writing an .alder buffer
  preview = true, -- generators show their diff before writing
  path = nil, -- an alder checkout to install the parser from (grammar development)
  lsp = true, -- attach `alder lsp`; false keeps CLI mode
  keys = { generate = '<leader>ag', diagnostics = '<leader>ac', explain = '<leader>ae', run = '<leader>ar', test = '<leader>at', test_at = '<leader>aT', mutate = '<leader>am', scratch = '<leader>ax', routes = '<leader>au', send = '<leader>as', scratch_value = '<leader>ao' }, -- each can be false
  revision = nil, -- a tag of tapegram/alder to install the parser from, e.g. 'v0.2.0'
}

M.options = vim.deepcopy(M.defaults)

local warned_repl = false
function M.reset_warned() warned_repl = false end

function M.set(opts)
  opts = vim.deepcopy(opts or {})
  -- keys.repl is the old name of keys.scratch
  if opts.keys and opts.keys.repl ~= nil then
    if opts.keys.scratch == nil then opts.keys.scratch = opts.keys.repl end
    opts.keys.repl = nil
    if not warned_repl then
      warned_repl = true
      vim.notify('alder: keys.repl is now keys.scratch (<leader>ax opens scratch.alder; the REPL is deprecated)', vim.log.levels.WARN)
    end
  end
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
end

return M
