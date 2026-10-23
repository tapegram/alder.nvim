local M = {}

M.defaults = {
  cmd = 'alder', -- the alder binary
  check_on_save = true, -- run `alder check` after writing an .alder buffer
  preview = true, -- generators show their diff before writing
  path = nil, -- an alder checkout to install the parser from (grammar development)
  lsp = true, -- attach `alder lsp`; false keeps CLI mode
  keys = { generate = '<leader>ag', diagnostics = '<leader>ac', explain = '<leader>ae', run = '<leader>ar', test = '<leader>at', test_at = '<leader>aT', mutate = '<leader>am', repl = '<leader>ax', routes = '<leader>au', send = '<leader>as' }, -- each can be false
  revision = nil, -- a tag of tapegram/alder to install the parser from, e.g. 'v0.2.0'
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
