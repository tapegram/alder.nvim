local form = require('alder.form')

local fields = {
  { name = 'page', kind = 'page', required = true, value = 'Posts.Index', source = 'here', valid = true, choices = { 'Posts.Index', 'Posts.Show' } },
  { name = 'name', kind = 'text', required = true, value = '', valid = false, why = 'required' },
  { name = 'fields', kind = 'fieldList', value = '', valid = true },
  { name = 'example', kind = 'bool', flag = true, value = 'true', source = 'default', valid = true },
}

test('form: lines show values, labels, notes and toggles', function()
  local lines, marks = form.lines(fields, {})
  assert(vim.deep_equal(lines, { 'Posts.Index', '', '', '[x] example' }), vim.inspect(lines))
  assert(marks[1].label == 'page     ' and marks[1].note == 'from the cursor' and marks[1].note_hl == 'Comment', vim.inspect(marks[1]))
  assert(marks[2].label == 'name     ' and marks[2].note == 'required' and marks[2].note_hl == 'Comment', vim.inspect(marks[2]))
  assert(marks[3].note == nil, vim.inspect(marks[3]))
  assert(marks[4].label == '' and marks[4].note == 'default', vim.inspect(marks[4]))
end)

test('form: a bool with an empty value renders unchecked, with no note', function()
  local lines, marks = form.lines({ { name = 'blank', kind = 'bool', flag = true, value = '', source = '', valid = true } }, {})
  assert(lines[1] == '[ ] blank', vim.inspect(lines))
  assert(marks[1].label == '' and marks[1].note == nil, vim.inspect(marks[1]))
end)

test('form: typed text wins over the value; a why that is not "required" is an error', function()
  local f = vim.deepcopy(fields)
  f[2].value, f[2].why = 'bad name', 'not a message name: write Capitalised'
  local lines, marks = form.lines(f, { name = 'Del' })
  assert(lines[2] == 'Del', vim.inspect(lines))
  assert(marks[2].note == f[2].why and marks[2].note_hl == 'DiagnosticError', vim.inspect(marks[2]))
end)

test('form: sets merge the preset and the typed text, dropping empties', function()
  local got = form.sets({ page = 'Posts.Index' }, { name = 'Delete', fields = '' })
  assert(vim.deep_equal(got, { page = 'Posts.Index', name = 'Delete' }), vim.inspect(got))
  got = form.sets({ page = 'Posts.Index' }, { page = '' })
  assert(vim.deep_equal(got, {}), 'clearing a preset field drops it')
end)

test('form: a default bool is not sent until it is toggled', function()
  assert(form.sets({}, {}).example == nil, 'the server re-decides a default switch')
  assert(form.sets({}, { example = 'false' }).example == 'false')
  assert(form.sets({}, { example = 'true' }).example == 'true')
end)

test('form: toggle, options, first_invalid', function()
  assert(form.toggle('[x] example') == '[ ] example' and form.toggle('[ ] example') == '[x] example')
  assert(form.is_on('[x] example') and not form.is_on('[ ] example'))
  assert(vim.deep_equal(form.options(fields[1], ''), { 'Posts.Index', 'Posts.Show' }))
  assert(vim.deep_equal(form.options(fields[1], 'show'), { 'Posts.Show' }))
  assert(vim.deep_equal(form.options(fields[2], 'x'), {}), 'no choices → no options')
  assert(form.first_invalid(fields) == 2)
  assert(form.first_invalid({ fields[1] }) == nil)
end)
