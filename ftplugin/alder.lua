if vim.b.did_ftplugin_alder then return end
vim.b.did_ftplugin_alder = true

vim.bo.commentstring = '-- %s'
vim.bo.comments = ':--'
vim.bo.shiftwidth = 2
vim.bo.tabstop = 2
vim.bo.softtabstop = 2
vim.bo.expandtab = true
-- generators edit files on disk; reload them without a W11 prompt (they refuse while modified)
vim.bo.autoread = true

if pcall(vim.treesitter.start) then
  vim.wo[0][0].foldmethod = 'expr'
  vim.wo[0][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
  vim.wo[0][0].foldlevel = 99
  if pcall(require, 'nvim-treesitter') then
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end
end

vim.b.undo_ftplugin = (vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. ' | ') or '')
  .. 'setl commentstring< comments< shiftwidth< tabstop< softtabstop< expandtab< autoread< indentexpr<'
  .. ' | unlet! b:did_ftplugin_alder'
