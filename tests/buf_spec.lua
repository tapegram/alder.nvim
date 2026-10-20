local H = require('helpers')
local B = require('alder.buf')

local function buffer(lines, ft, name)
  local b = vim.api.nvim_create_buf(true, false)
  if name then vim.api.nvim_buf_set_name(b, name) end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if ft then vim.bo[b].filetype = 'alder' end
  return b
end

local SRC = {
  '-- a comment', 'module Todos.Index', '', 'import Todo', '',
  'x : Int', 'x = 1', '',
  'test "first (1)" = x == 1', 'test "second \\"q\\"" =', '  x == 1', '', 'y = 2',
}

test('buf: module name by regex (no parser); nested modules are dotted', function()
  local b = buffer(SRC, nil, H.tmpdir() .. '/app/Todos/Index.alder')
  assert(B.module_name(b) == 'Todos.Index', tostring(B.module_name(b)))
  assert(B.module_name(buffer({ 'x = 1' })) == nil)
end)

test('buf: test at or above the cursor by regex', function()
  local b = buffer(SRC)
  assert(B.test_at(b, 8) == 'first (1)')
  assert(B.test_at(b, 10) == 'second \\"q\\"') -- raw text between the quotes
  assert(B.test_at(b, 12) == 'second \\"q\\"') -- the nearest above
  assert(B.test_at(b, 6) == nil)
end)

test('buf: module name and test by tree-sitter', function()
  H.ensure_parser()
  local b = buffer(SRC, 'alder', H.tmpdir() .. '/app/Todos/Index.alder')
  assert(B.module_name(b) == 'Todos.Index', tostring(B.module_name(b)))
  assert(B.test_at(b, 8) == 'first (1)')
  assert(B.test_at(b, 12) == 'second \\"q\\"')
  assert(B.test_at(b, 6) == nil)
end)

test('test: run_pattern escapes the name for Go regexp', function()
  local T = require('alder.test')
  assert(T.run_pattern('Todo', 'first (1)') == '^Todo "first \\(1\\)"$', T.run_pattern('Todo', 'first (1)'))
  assert(T.run_pattern('Todo', nil) == '^Todo ')
  -- alder names a test by its source text: the escape's backslash is escaped, the quotes stay literal
  local p = T.run_pattern('Todos.Index', 'a (b) \\"c\\"')
  assert(p == '^Todos.Index "a \\(b\\) \\\\"c\\\\""$', p)
end)
