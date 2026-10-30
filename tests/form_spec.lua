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

-- alder#45: the server sends each field's help and example, and marks agent-oriented flags.
local described = {
  { name = 'page', kind = 'page', required = true, value = 'Posts.Index', source = 'here', valid = true, help = 'the page the message belongs to', example = 'Posts.Index' },
  { name = 'name', kind = 'text', required = true, value = 'Archive', source = 'default', valid = true, help = "the message's name", example = 'Archive' },
  { name = 'fields', kind = 'fieldList', value = '', valid = true, help = 'the values it carries', example = 'note:Text' },
  { name = 'when', kind = 'text', flag = true, value = '', valid = true, help = 'show the button only when this holds', example = 'model.canWrite', agent = true },
}

test('form: visible leaves out the agent-oriented flags', function()
  local names = vim.tbl_map(function(f) return f.name end, form.visible(described))
  assert(vim.deep_equal(names, { 'page', 'name', 'fields' }), vim.inspect(names))
  assert(#form.visible(fields) == #fields, 'fields without the mark all show')
  assert(vim.deep_equal(form.visible(nil), {}))
end)

test('form: the note carries the help after where the value came from', function()
  local _, marks = form.lines(form.visible(described), {})
  assert(marks[1].note == 'from the cursor · the page the message belongs to' and marks[1].note_hl == 'Comment', vim.inspect(marks[1]))
  assert(marks[2].note == "default · the message's name", vim.inspect(marks[2]))
  assert(marks[3].note == 'the values it carries', vim.inspect(marks[3]))
  -- an error still wins
  local f = vim.deepcopy(described)
  f[2].valid, f[2].why = false, 'not a name'
  _, marks = form.lines(f, {})
  assert(marks[2].note == 'not a name' and marks[2].note_hl == 'DiagnosticError', vim.inspect(marks[2]))
end)

test('form: a cleared field says which value the server uses instead', function()
  local lines, marks = form.lines(form.visible(described), { name = '' })
  assert(lines[2] == '', vim.inspect(lines))
  assert(marks[2].note == 'default: Archive', vim.inspect(marks[2]))
  _, marks = form.lines(form.visible(described), { page = '' })
  assert(marks[1].note == 'from the cursor: Posts.Index', vim.inspect(marks[1]))
end)

test('form: example_line is the focused field\'s example, nil without one', function()
  assert(form.example_line(described[3]) == 'e.g. note:Text', form.example_line(described[3]))
  assert(form.example_line(fields[1]) == nil)
  assert(form.example_line({ name = 'x', kind = 'bool', example = '' }) == nil)
end)

test('form: first_to_fill is the first invalid field, else the first at its starting value', function()
  assert(form.first_to_fill(fields) == 2)
  assert(form.first_to_fill(described) == 2, 'name is at its example')
  local f = vim.deepcopy(described)
  f[2].source = 'you'
  assert(form.first_to_fill(f) == nil)
end)

local H = require('helpers')

test('form: module_dirs lists the folders under app/ as dotted prefixes, shallow first', function()
  local root = H.tmpdir()
  H.write(root .. '/app/App.alder', 'module App\n')
  H.write(root .. '/app/Sites/Clarity/Index.alder', 'module Sites.Clarity.Index\n')
  H.write(root .. '/app/Posts/Index.alder', 'module Posts.Index\n')
  H.write(root .. '/app/lowercase/X.alder', '')
  assert(vim.deep_equal(form.module_dirs(root), { 'Posts.', 'Sites.', 'Sites.Clarity.' }), vim.inspect(form.module_dirs(root)))
  assert(vim.deep_equal(form.module_dirs(root .. '/nope'), {}))
end)

test('form: module_path and module_help show where a module name lands', function()
  assert(form.module_path('Sites.Clarity.Index') == 'app/Sites/Clarity/Index.alder')
  assert(form.module_help('Posts.Show') == 'Posts.Show → app/Posts/Show.alder', form.module_help('Posts.Show'))
  assert(form.module_help('') == 'Sites.Clarity.Index → app/Sites/Clarity/Index.alder', form.module_help(''))
  assert(form.module_help('Sites.Clarity.') == 'Sites.Clarity.Index → app/Sites/Clarity/Index.alder', form.module_help('Sites.Clarity.'))
end)

test('form: module_suggest completes a typed prefix from the existing folders', function()
  local dirs = { 'Posts.', 'Sites.', 'Sites.Clarity.' }
  assert(vim.deep_equal(form.module_suggest(dirs, ''), dirs))
  assert(vim.deep_equal(form.module_suggest(dirs, 'Sites.'), { 'Sites.Clarity.' }), vim.inspect(form.module_suggest(dirs, 'Sites.')))
  assert(vim.deep_equal(form.module_suggest(dirs, 'Si'), { 'Sites.', 'Sites.Clarity.' }))
  assert(#form.module_suggest(dirs, 'Zzz') == 0)
  assert(#form.module_suggest(dirs, 'Sites.Clarity.') == 0, 'an exact folder has nothing left to complete')
end)
