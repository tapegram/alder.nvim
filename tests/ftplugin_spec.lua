local H = require('helpers')

-- project builds a temp app with two modules and an importing file; returns its root.
local function project()
  local root = H.tmpdir()
  H.write(root .. '/app/Entry.alder', 'module Entry\n')
  H.write(root .. '/app/Posts/Index.alder', 'module Posts.Index\n')
  H.write(root .. '/app/Home.alder', 'module Home\n\nimport Entry\nimport Posts.Index\n')
  return root
end

local function gf_on(root, lnum, col)
  vim.cmd.edit(root .. '/app/Home.alder')
  vim.api.nvim_win_set_cursor(0, { lnum, col })
  vim.cmd.normal({ 'gf', bang = true })
  return vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0))
end

test('ftplugin gf: an import of Entry opens app/Entry.alder', function()
  local root = project()
  assert(gf_on(root, 3, 8) == root .. '/app/Entry.alder', vim.api.nvim_buf_get_name(0))
end)

test('ftplugin gf: Posts.Index opens app/Posts/Index.alder', function()
  local root = project()
  assert(gf_on(root, 4, 10) == root .. '/app/Posts/Index.alder', vim.api.nvim_buf_get_name(0))
end)

test('ftplugin gf: works from a nested buffer too', function()
  local root = project()
  H.write(root .. '/app/Posts/Show.alder', 'module Posts.Show\n\nimport Entry\n')
  vim.cmd.edit(root .. '/app/Posts/Show.alder')
  vim.api.nvim_win_set_cursor(0, { 3, 8 })
  vim.cmd.normal({ 'gf', bang = true })
  assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == root .. '/app/Entry.alder')
end)

test('ftplugin: include matches import lines', function()
  vim.cmd.edit(project() .. '/app/Home.alder')
  assert(vim.fn.match('import Entry', vim.bo.include) == 0)
  assert(vim.fn.match('  import Posts.Index', vim.bo.include) == 0)
  assert(vim.fn.match('x = 1', vim.bo.include) == -1)
end)

test('ftplugin make: :make lists alder check errors in the quickfix list', function()
  local root = H.tmpdir()
  H.write(root .. '/app/Home.alder', 'module Home\n\nx = undefinedThing\n')
  vim.cmd.edit(root .. '/app/Home.alder')
  vim.cmd('cd /') -- reported paths are relative to the root, whatever the cwd
  vim.cmd('silent make')
  local qf = vim.tbl_filter(function(i) return i.valid == 1 end, vim.fn.getqflist())
  assert(#qf == 2, vim.inspect(vim.fn.getqflist()))
  assert(qf[1].lnum == 3 and qf[1].col == 1 and qf[1].type == 'e' and qf[1].nr == 7 and qf[1].text:find('no type signature', 1, true), vim.inspect(qf[1]))
  assert(qf[2].lnum == 3 and qf[2].col == 5 and qf[2].nr == 2 and qf[2].text:find('unknown name', 1, true), vim.inspect(qf[2]))
  assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(qf[2].bufnr)) == root .. '/app/Home.alder',
    vim.api.nvim_buf_get_name(qf[2].bufnr))
  vim.cmd('cd -')
end)

test('ftplugin %: jumps between HTML tags', function()
  local file = H.tmpdir() .. '/V.alder'
  H.write(file, 'view = <div class="a">\n  <p>hi</p>\n</div>\n')
  vim.cmd.edit(file)
  assert(vim.b.match_words and vim.b.match_ignorecase == 0, tostring(vim.b.match_words))
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  vim.cmd.normal('%')
  assert(vim.fn.line('.') == 3, vim.fn.line('.'))
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  vim.cmd.normal('%')
  assert(vim.fn.line('.') == 2 and vim.fn.col('.') == 9, vim.fn.col('.'))
end)

test('ftplugin: undo_ftplugin resets the options', function()
  vim.cmd.edit(project() .. '/app/Home.alder')
  vim.cmd('setfiletype text | let b:undo = b:undo_ftplugin | exe b:undo')
  assert(vim.b.match_words == nil and vim.bo.includeexpr == '' and vim.bo.suffixesadd == '')
end)
