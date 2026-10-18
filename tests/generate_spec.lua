local H = require('helpers')
local generate = require('alder.generate')

local function preview_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match('alder://preview$') then return b end
  end
end

test('generate: :Alder new page previews, then <CR> applies and opens the page', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  vim.cmd('Alder new page Hello /hello')
  assert(H.wait(20000, function() return preview_buf() ~= nil end), 'no preview')
  local buf = preview_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(text:find('created app/Hello.alder', 1, true), text)
  assert(text:find('page "/hello"', 1, true), text)
  assert(not vim.uv.fs_stat(app .. '/app/Hello.alder'), 'the preview wrote the file')
  generate.apply_preview(buf)
  assert(H.wait(20000, function() return vim.uv.fs_stat(app .. '/app/Hello.alder') ~= nil end), 'not applied')
  assert(H.wait(5000, function() return vim.api.nvim_buf_get_name(0):match('Hello%.alder$') end), 'the new page did not open')
end)

test('generate: refused while an .alder buffer has unsaved changes', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { '-- unsaved' })
  local messages, restore = H.capture_notify()
  vim.cmd('Alder new page Hello /hello')
  restore()
  assert(messages[1] and messages[1].msg == 'alder: save all buffers first (:wall)', vim.inspect(messages))
  assert(preview_buf() == nil)
end)

test('generate: a refusal is shown verbatim', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  local messages, restore = H.capture_notify()
  local done = false
  generate.run({ 'new', 'page', 'Hello', '/hello', '--list', 'NoSuchTable' }, { on_done = function() done = true end })
  assert(H.wait(20000, function() return done end))
  restore()
  local r = vim.system({ 'alder', 'new', 'page', 'Hello', '/hello', '--list', 'NoSuchTable', '--json', '--dry-run', '--dir', app },
    { text = true, cwd = app }):wait()
  local err = vim.json.decode(r.stdout).error
  assert(err and messages[1] and messages[1].msg == err, vim.inspect({ messages, err }))
end)

test('generate: render lists files, migration, holes, diagnostics and the diff', function()
  local lines = generate.render({
    files = { { path = 'app/T.alder', action = 'created' } }, diff = '--- a\n+++ b',
    migration = { 'add table t' }, holes = { { module = 'T', decl = 'x', name = 'v', type = 'Int', file = 'app/T.alder', line = 3, col = 5 } },
    diagnostics = { { file = 'app/T.alder', line = 3, col = 5, code = 'W0002', message = 'a hole' } },
  })
  local text = table.concat(lines, '\n')
  for _, want in ipairs({ 'created app/T.alder', 'add table t', '?v : Int', 'app/T.alder:3:5 W0002 a hole', '+++ b' }) do
    assert(text:find(want, 1, true), want .. ' missing from:\n' .. text)
  end
end)

test('generate: a second preview gets the name alder://preview', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  for _, n in ipairs({ 'A', 'B' }) do
    vim.cmd.edit(app .. '/app/App.alder') -- the preview window has no app root of its own
    local done = false
    generate.run({ 'new', 'page', n, '/' .. n:lower() }, { on_done = function() done = true end })
    assert(H.wait(20000, function() return done end))
  end
  local count = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match('alder://preview$') then count = count + 1 end
  end
  assert(count == 1, 'previews: ' .. count)
  local text = table.concat(vim.api.nvim_buf_get_lines(preview_buf(), 0, -1, false), '\n')
  assert(text:find('app/B.alder', 1, true), text)
end)

test('generate: a refusal with diagnostics goes to its own quickfix list, not the buffers', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  vim.fn.setqflist({}, ' ', { title = 'mine', items = { { filename = app .. '/app/App.alder', lnum = 1, text = 'x' } } })
  local json = { error = 'refused', diagnostics = { { file = 'app/Home.alder', line = 2, col = 3, code = 'E0001', message = 'bad' } } }
  local orig = require('alder.cli').run
  require('alder.cli').run = function(_, _, cb) cb({ code = 1, stdout = '', stderr = '', objects = { json }, json = json }) end
  local messages, restore = H.capture_notify()
  generate.run({ 'fill', 'Home.x', '--hole', '?v' })
  restore()
  require('alder.cli').run = orig
  assert(messages[1].msg == 'refused')
  local q = vim.fn.getqflist({ title = 0, items = 0, nr = '$' })
  assert(q.title == 'alder fill' and #q.items == 1 and q.items[1].text == 'E0001 bad', vim.inspect(q))
  assert(#vim.diagnostic.get(0) == 0, 'refusal diagnostics were set on a buffer')
  vim.cmd('colder')
  assert(vim.fn.getqflist({ title = 0 }).title == 'mine')
end)

test('generate: :Alder fill ... - is refused, fill --list is read-only', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  local messages, restore = H.capture_notify()
  vim.cmd('Alder fill Home.x -')
  restore()
  assert(messages[1] and messages[1].msg:find(':AlderFill', 1, true), vim.inspect(messages))
  vim.cmd('Alder fill --list')
  assert(H.wait(20000, function() return preview_buf() ~= nil end), 'no output')
  local buf = preview_buf()
  messages, restore = H.capture_notify()
  vim.api.nvim_buf_call(buf, function() vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false) end)
  restore()
  assert(messages[1] and messages[1].msg:find('nothing to apply', 1, true), vim.inspect(messages))
  assert(preview_buf() == buf, 'the read-only output was consumed')
end)
