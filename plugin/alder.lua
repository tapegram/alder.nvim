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
