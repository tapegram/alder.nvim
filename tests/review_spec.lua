local review = require('alder.review')
local ui = require('alder.ui')
local H = require('helpers')

local plan = {
  files = {
    { path = 'app/Posts/Index.alder', action = 'edited', before = 'a\nb\nc\n', after = 'a\nB\nc\n' },
    { path = 'app/New.alder', action = 'created', before = vim.NIL, after = 'module New\n' },
  },
  holes = { { name = 'delete', type = 'Task Nav', module = 'Posts.Index', decl = 'update', arm = 'Delete' } },
  imports = { 'Post' },
  migration = {},
  diagnostics = {},
  error = '',
}

test('review: model builds notes and unified diffs', function()
  local m = review.model(ui.plain(plan))
  assert(m.can_apply)
  assert(vim.deep_equal(m.notes, { '? delete : Task Nav  (Posts.Index.update.Delete)', 'import Post' }), vim.inspect(m.notes))
  assert(#m.files == 2 and m.files[1].path == 'app/Posts/Index.alder' and not m.files[1].new, vim.inspect(m.files))
  assert(m.files[1].diff:find('@@', 1, true) and m.files[1].diff:find('%-b\n%+B'), m.files[1].diff)
  assert(m.files[2].new and m.files[2].diff:find('+module New', 1, true), m.files[2].diff)
end)

test('review: an error forbids applying and heads the notes', function()
  local m = review.model({ error = 'the result does not check', diagnostics = { { file = 'app/X.alder', line = 3, col = 1, code = 'E0003', message = 'expected Int', severity = 'error' } }, files = {} })
  assert(not m.can_apply)
  assert(m.notes[1] == '✗ the result does not check' and m.notes[2] == 'app/X.alder:3:1 E0003 expected Int', vim.inspect(m.notes))
end)

test('review: open shows notes, files and the diff; q goes back, <CR> applies', function()
  local applied, back = false, false
  assert(review.open(plan, { id = 'new msg', on_apply = function() applied = true end, on_back = function() back = true end }))
  local text = H.float_text()
  assert(text:find(' new msg  <CR> apply · Esc back ', 1, true), text)
  assert(text:find(' files ', 1, true) and text:find('~ app/Posts/Index.alder', 1, true) and text:find('@@', 1, true), text)
  vim.api.nvim_feedkeys('q', 'x', false)
  assert(back and not applied)
  assert(H.float_text() == '', 'floats left after q')
  review.open(plan, { id = 'new msg', on_apply = function() applied = true end, on_back = function() end })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  assert(applied and H.float_text() == '')
end)

test('review: cannot apply → <CR> does nothing, q closes', function()
  local applied = false
  review.open({ error = 'nope', files = {}, diagnostics = {} }, { id = 'new page', on_apply = function() applied = true end, on_back = function() end })
  assert(H.float_text():find('✗ cannot apply · q close', 1, true), H.float_text())
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  assert(not applied and H.float_text() ~= '')
  vim.api.nvim_feedkeys('q', 'x', false)
  assert(H.float_text() == '')
end)
