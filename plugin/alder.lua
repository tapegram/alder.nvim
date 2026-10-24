if vim.g.loaded_alder then return end
vim.g.loaded_alder = true

vim.filetype.add({ extension = { alder = 'alder' } })

local group = vim.api.nvim_create_augroup('alder', { clear = true })

vim.api.nvim_create_autocmd('User', {
  group = group,
  pattern = 'TSUpdate',
  callback = function() require('alder.parser').register() end,
})

require('alder.parser').register()

for name, link in pairs({
  AlderScratchValue = 'Comment', AlderScratchPending = 'NonText',
  AlderScratchError = 'DiagnosticError', AlderScratchNote = 'DiagnosticInfo',
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

-- the project-level maps (generate, run, test, scratch, routes) work in any buffer of a project; setup() redoes them
require('alder.keys').attach_global()

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'alder',
  callback = function(ev) require('alder.lsp').start(ev.buf) end,
})

vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  pattern = '*.alder',
  callback = function(ev)
    if vim.b[ev.buf].alder_lsp then return end -- the server publishes the diagnostics
    if not require('alder.config').options.check_on_save then return end
    local r = require('alder.root').for_buf(ev.buf)
    if r then require('alder.check').run(r) end
  end,
})

-- A file a plan created (b:alder_new) gets its directory on the first :w (R10).
vim.api.nvim_create_autocmd('BufWritePre', {
  group = group,
  callback = function(ev)
    if vim.b[ev.buf].alder_new then
      vim.fn.mkdir(vim.fs.dirname(vim.api.nvim_buf_get_name(ev.buf)), 'p')
      vim.b[ev.buf].alder_new = nil
    end
  end,
})

vim.api.nvim_create_user_command('AlderCheck', function()
  require('alder.check').for_current({ open_qf = true })
end, { desc = 'alder check: diagnostics in buffers, other files in the quickfix list' })

vim.api.nvim_create_user_command('AlderTest', function(o)
  require('alder.test').for_current({ args = o.fargs })
end, { nargs = '*', desc = 'alder test [args]: failures in the quickfix list' })

vim.api.nvim_create_user_command('AlderMutate', function(o)
  require('alder.test').mutate_for_current({ args = o.fargs })
end, { nargs = '*', desc = 'alder test --mutate [args] in the background: survivors in the quickfix list' })

vim.api.nvim_create_user_command('AlderRepl', function()
  vim.notify(require('alder.repl').DEPRECATED, vim.log.levels.WARN)
  require('alder.repl').for_current()
end, { desc = 'DEPRECATED: alder repl --in <this module> in a split; use :AlderScratch' })

vim.api.nvim_create_user_command('AlderScratch', function()
  local r = require('alder.project').require_root()
  if r then require('alder.scratch').open(r) end
end, { desc = 'open scratch.alder at the app root: each `> expr` line shows its value' })

vim.api.nvim_create_user_command('AlderRoutes', function()
  require('alder.routes').pick()
end, { desc = 'the routes of the app in a fuzzy picker; select one to jump to its declaration' })

vim.api.nvim_create_user_command('AlderDiagnostics', function()
  require('alder.keys').actions.diagnostics()
end, { desc = 'alder diagnostics of the open buffers in the quickfix list' })

vim.api.nvim_create_user_command('AlderFix', function()
  require('alder.check').fix_at_cursor()
end, { desc = 'apply the compiler fix under the cursor' })

vim.api.nvim_create_user_command('AlderExplain', function(o)
  require('alder.check').explain(o.args)
end, { nargs = '?', desc = 'alder explain <code> (default: the diagnostic under the cursor)' })

vim.api.nvim_create_user_command('Alder', function(o)
  require('alder.commands').alder(o.fargs)
end, {
  nargs = '+',
  complete = function(arglead, cmdline) return require('alder.commands').complete(arglead, cmdline) end,
  desc = 'run alder <command>: generators preview their diff first',
})

local STATIC_IDS = { 'new form', 'new msg', 'new decl', 'new test', 'edit page', 'remove page', 'new page', 'new table', 'new capability', 'new admin', 'new auth', 'new type', 'new silo', 'edit table', 'edit decl', 'edit auth', 'edit session', 'remove table', 'regen admin' }

-- generator_ids completes :AlderGenerate from the server's list, else from a static one.
local function generator_ids()
  local buf = vim.api.nvim_get_current_buf()
  local c = require('alder.lsp').client(buf)
  if c then
    local pos = vim.api.nvim_win_get_cursor(0)
    local res = c:request_sync('alder/generators', {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = pos[1] - 1, character = pos[2] },
    }, 1000, buf)
    if res and res.result and res.result.generators then
      return vim.tbl_map(function(g) return g.id end, res.result.generators)
    end
  end
  return STATIC_IDS
end

vim.api.nvim_create_user_command('AlderGenerate', function(o)
  local id = vim.trim(o.args)
  require('alder.modal').open(vim.api.nvim_get_current_buf(), { generator = id ~= '' and id or nil })
end, {
  nargs = '*', -- ids have spaces: `new msg`
  complete = function(_, cmdline)
    local typed = cmdline:gsub('^%S+%s+', '')
    local out = {}
    for _, id in ipairs(generator_ids()) do
      if vim.startswith(id, typed) then
        -- the command line completes its last word, so offer the id from there on
        local done = typed:match('^.*%s') or ''
        table.insert(out, id:sub(#done + 1))
      end
    end
    return out
  end,
  desc = 'alder generate [id]: the generator modal — search, form, live preview, apply',
})

-- Neovim's own code action menu (gra) runs a generator action through this client command: the
-- modal opens preset with the generator and the values the server filled from the cursor.
vim.lsp.commands['alder.generate'] = function(cmd, ctx)
  local g = require('alder.ui').plain(cmd.arguments[1])
  require('alder.modal').open(ctx.bufnr, { generator = g.id, sets = g.sets })
end
