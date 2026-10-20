local H = require('helpers')
local test_ = require('alder.test')

test('test: a failure with sides becomes a quickfix entry at its test line', function()
  local e = test_.entry('/app', { module = 'Todo', name = 'countOpen ignores done', ok = false,
    file = 'app/Todo.alder', line = 88, col = 1, left = '3', right = '2', trace = {}, ms = 1 })
  assert(e.filename == '/app/app/Todo.alder' and e.lnum == 88 and e.col == 1 and e.type == 'E', vim.inspect(e))
  assert(e.text == 'FAIL "countOpen ignores done" — left: 3  right: 2', e.text)
end)

test('test: an error and a note print instead of sides; newlines flatten', function()
  local e = test_.entry('/app', { module = 'M', name = 'n', ok = false, file = 'app/M.alder', line = 2, col = 1,
    error = 'boom\n  here', trace = {} })
  assert(e.text == 'FAIL "n" — error: boom here', e.text)
  e = test_.entry('/app', { module = 'M', name = 'n', ok = false, file = 'app/M.alder', line = 2, col = 1,
    note = 'sides print the same', trace = {} })
  assert(e.text == 'FAIL "n" — note: sides print the same', e.text)
end)

test('test: a passing result is no entry; a result without a position keeps module and name', function()
  assert(test_.entry('/app', { module = 'M', name = 'n', ok = true }) == nil)
  local e = test_.entry('/app', { module = 'M', name = 'n', ok = false, error = 'crashed' })
  assert(e.filename == nil and e.lnum == 0 and e.text == 'FAIL M "n" — error: crashed', vim.inspect(e))
end)

test('test: summary counts', function()
  assert(test_.summary({ { ok = true }, { ok = false }, { ok = true } }) == '2 passed, 1 failed')
  assert(test_.summary({}) == '0 passed, 0 failed')
end)

-- run_tests runs test.run and waits for it to report.
local function run_tests(app, o)
  o = o or {}
  local done = false
  o.on_done = function() done = true end
  require('alder.test').run(app, o)
  assert(H.wait(120000, function() return done end), 'alder test did not finish')
end

local function qf_open()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'quickfix' then return true end
  end
  return false
end

test('test: a failing test lands in quickfix at its line; a clean run closes the list', function()
  local app = H.new_app()
  local file = app .. '/app/Demo.alder'
  H.write(file, 'module Demo\n\nanswer : Int\nanswer = 41\n\ntest "answer is 42" = answer == 42\n')
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(run_tests, app)
  restore()
  assert(ok, err)
  local qf = vim.fn.getqflist({ title = 0, items = 0 })
  assert(qf.title == 'alder test', qf.title)
  local hit
  for _, it in ipairs(qf.items) do
    if it.text:find('answer is 42', 1, true) then hit = it end
  end
  assert(hit and hit.lnum == 6 and vim.api.nvim_buf_get_name(hit.bufnr):find('Demo.alder', 1, true), vim.inspect(qf.items))
  assert(msgs[#msgs].msg:find('1 failed', 1, true), vim.inspect(msgs))

  H.write(file, 'module Demo\n\nanswer : Int\nanswer = 42\n\ntest "answer is 42" = answer == 42\n')
  run_tests(app)
  assert(#vim.fn.getqflist() == 0)
  assert(not qf_open(), 'the quickfix window stayed open after a clean run')
end)

test('test: a compile error takes the check path', function()
  local app = H.new_app()
  H.write(app .. '/app/Demo.alder', 'module Demo\n\nbroken : Int\nbroken = "x"\n')
  run_tests(app)
  local qf = vim.fn.getqflist({ title = 0, items = 0 })
  assert(qf.title == 'alder check' and #qf.items > 0 and qf.items[1].text:find('E0003', 1, true), vim.inspect(qf))
end)

test('test: write_app_buffers writes modified app buffers and returns the one it could not write', function()
  local app = H.new_app()
  local good, bad = app .. '/app/Good.alder', app .. '/app/Bad.alder'
  H.write(good, 'module Good\n\nx : Int\nx = 1\n')
  H.write(bad, 'module Bad\n\ny : Int\ny = 1\n')
  vim.cmd.edit(good)
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { 'x = 2' })
  vim.cmd.edit(bad)
  local bbuf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { 'y = 2' })
  vim.uv.fs_chmod(bad, tonumber('444', 8))
  vim.bo[bbuf].readonly = true
  local failed = test_.write_app_buffers(app)
  vim.uv.fs_chmod(bad, tonumber('644', 8))
  assert(#failed == 1 and failed[1]:find('Bad.alder', 1, true), vim.inspect(failed))
  assert(H.read(good):find('x = 2', 1, true), 'the writable buffer was not written')
end)

test('test: the run proceeds with a WARN when a modified buffer could not be written', function()
  local app = H.new_app()
  local file = app .. '/app/Demo.alder'
  H.write(file, 'module Demo\n\nanswer : Int\nanswer = 42\n\ntest "answer is 42" = answer == 42\n')
  vim.cmd.edit(file)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(0, 4, 4, false, { '-- edit' })
  vim.uv.fs_chmod(file, tonumber('444', 8))
  vim.bo[buf].readonly = true
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(run_tests, app)
  restore()
  vim.uv.fs_chmod(file, tonumber('644', 8))
  assert(ok, err)
  local warn
  for _, m in ipairs(msgs) do
    if m.level == vim.log.levels.WARN and m.msg:find('not written', 1, true) and m.msg:find('Demo.alder', 1, true) then warn = m end
  end
  assert(warn, vim.inspect(msgs))
  assert(msgs[#msgs].msg:find(' 0 failed', 1, true), vim.inspect(msgs))
end)

test('test: a failed result without a line warns once (an older alder)', function()
  local msgs, restore = H.capture_notify()
  test_.warn_positions('/app', { { name = 'a', ok = false }, { name = 'b', ok = false }, { name = 'c', ok = true } })
  restore()
  local n = 0
  for _, m in ipairs(msgs) do
    if m.level == vim.log.levels.WARN and m.msg:find('position', 1, true) then n = n + 1 end
  end
  assert(n == 1, vim.inspect(msgs))
  msgs, restore = H.capture_notify()
  test_.warn_positions('/app', { { name = 'a', ok = false, line = 0 } }) -- line 0 is a known "no position"
  restore()
  assert(#msgs == 0, vim.inspect(msgs))
end)
