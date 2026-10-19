local picker = require('alder.picker')

local items = {
  { id = 'new msg', summary = 'a message and its update arm', here = true },
  { id = 'new form', summary = 'a form, its message and arm', here = true },
  { id = 'new page', summary = 'a page module' },
  { id = 'edit table', summary = 'change a table' },
}

test('picker: an empty query keeps every item in order', function()
  local got = picker.filter(items, '')
  assert(#got == 4 and got[1].id == 'new msg' and got[4].id == 'edit table', vim.inspect(got))
  assert(got ~= items, 'filter must return a copy')
end)

test('picker: fuzzy on id and summary', function()
  local got = picker.filter(items, 'tbl')
  assert(#got == 1 and got[1].id == 'edit table', vim.inspect(got))
  got = picker.filter(items, 'page')
  assert(got[1].id == 'new page', vim.inspect(got))
  assert(#picker.filter(items, 'zzzz') == 0)
end)

test('picker: lines align summaries and mark the groups', function()
  local lines, marks, headings = picker.lines(items, true)
  assert(lines[1] == 'new msg     a message and its update arm', vim.inspect(lines))
  assert(lines[4] == 'edit table  change a table', vim.inspect(lines))
  assert(marks[1].row == 1 and marks[1].col == #'new msg     ' and marks[1].hl == 'Comment', vim.inspect(marks))
  assert(#headings == 2 and headings[1].row == 1 and headings[1].text == '── here ──', vim.inspect(headings))
  assert(headings[2].row == 3 and headings[2].text == '── all ──', vim.inspect(headings))
  local _, _, none = picker.lines(items, false)
  assert(#none == 0)
  local empty = picker.lines({}, true)
  assert(#empty == 0)
end)
