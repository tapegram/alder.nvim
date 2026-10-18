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

vim.api.nvim_create_user_command('AlderCheck', function()
  require('alder.check').for_current({ open_qf = true })
end, { desc = 'alder check: diagnostics in buffers, other files in the quickfix list' })

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
