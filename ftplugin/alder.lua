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

-- gf on `import Posts.Index` opens <root>/app/Posts/Index.alder
vim.bo.include = [[^\s*import\>]]
vim.bo.includeexpr = "v:lua.require'alder.ftplugin'.include(v:fname)"
vim.bo.suffixesadd = '.alder'
local root = require('alder.root').for_buf(0)
if root then vim.bo.path = root .. '/app,.' end

-- :make runs alder check on the project root; the root is entered first so the file
-- names (relative to it) resolve in the quickfix list whatever the cwd
local dir = root or vim.fn.getcwd()
vim.bo.makeprg = ('(echo "Entering directory %s"; %s check %s)'):format(vim.fn.escape(dir, '"\\$`%#'),
  vim.fn.shellescape(require('alder.config').options.cmd), vim.fn.shellescape(dir))
vim.bo.errorformat = table.concat({
  [[%DEntering directory %f]],
  [=[%f:%l:%c: %t%*[a-z][%*[A-Z]%n]: %m]=],
  [[%-G%.%#]], -- context, caret, fix and blank lines
}, ',')

-- % jumps between <div> and </div> (matchit ships with Neovim)
vim.b.match_ignorecase = 0
vim.b.match_words = [[<:>,<\@<=\([^/!][^ \t>]*\)[^>]*\%(>\|$\):<\@<=/\1>]]

require('alder.keys').attach(0)

vim.b.undo_ftplugin = (vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. ' | ') or '')
  .. 'setl commentstring< comments< shiftwidth< tabstop< softtabstop< expandtab< autoread< indentexpr< include< includeexpr< suffixesadd< path< makeprg< errorformat<'
  .. " | call v:lua.require'alder.keys'.detach(0)"
  .. ' | unlet! b:did_ftplugin_alder b:match_words b:match_ignorecase'
