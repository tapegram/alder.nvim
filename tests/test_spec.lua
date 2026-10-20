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

test('test: a passing run clears the compile diagnostics a failed run published', function()
  local app = H.new_app()
  local demo, other = app .. '/app/Demo.alder', app .. '/app/Other.alder'
  H.write(demo, 'module Demo\n\nbroken : Int\nbroken = "x"\n')
  H.write(other, 'module Other\n\nalsoBroken : Int\nalsoBroken = "y"\n')
  vim.cmd.edit(demo)
  local buf = vim.api.nvim_get_current_buf()
  local ns = require('alder.check').ns
  run_tests(app)
  assert(#vim.diagnostic.get(buf, { namespace = ns }) > 0, 'the failed run published no buffer diagnostics')
  local qf = vim.fn.getqflist({ title = 0, items = 0 })
  assert(qf.title == 'alder check' and #qf.items > 0, vim.inspect(qf))

  H.write(demo, 'module Demo\n\nfine : Int\nfine = 1\n')
  H.write(other, 'module Other\n\nalsoFine : Int\nalsoFine = 2\n')
  vim.api.nvim_buf_call(buf, function() vim.cmd('edit!') end)
  run_tests(app)
  assert(#vim.diagnostic.get(buf, { namespace = ns }) == 0, vim.inspect(vim.diagnostic.get(buf, { namespace = ns })))
  qf = vim.fn.getqflist({ title = 0, items = 0 })
  assert(qf.title ~= 'alder check' or #qf.items == 0, vim.inspect(qf))
  vim.cmd('cclose')
  vim.cmd('bwipeout! ' .. buf)
end)

test('test: clear_compiled leaves diagnostics an alder check published', function()
  local app = H.new_app()
  local check, T = require('alder.check'), require('alder.test')
  vim.cmd.edit(app .. '/app/App.alder')
  local buf = vim.api.nvim_get_current_buf()
  check.publish(app, { { code = 'W0001', severity = 'warning', file = 'app/App.alder', line = 1, col = 1, message = 'w' } })
  T.clear_compiled(app)
  assert(#vim.diagnostic.get(buf, { namespace = check.ns }) == 1, 'a check publish was cleared')
  check.publish(app, { { code = 'E0003', severity = 'error', file = 'app/App.alder', line = 1, col = 1, message = 'e' } }, 'alder test')
  T.clear_compiled(app)
  assert(#vim.diagnostic.get(buf, { namespace = check.ns }) == 0, 'a test publish was not cleared')
  vim.cmd('bwipeout!')
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

-- at_cursor_run runs test.at_cursor and waits for the run to finish.
local function at_cursor_run()
  local T = require('alder.test')
  local orig, done = T.for_current, false
  T.for_current = function(o) o = o or {}; o.on_done = function() done = true end; orig(o) end
  local ok, err = pcall(function()
    T.at_cursor()
    assert(H.wait(120000, function() return done end), 'did not finish')
  end)
  T.for_current = orig
  if not ok then error(err, 0) end
end

local function last_msg(msgs) return msgs[#msgs] and msgs[#msgs].msg end

test('test: <leader>aT runs only the test under the cursor', function()
  local app = H.new_app()
  local file = app .. '/app/Demo.alder'
  H.write(file, 'module Demo\n\ntest "bad (1)" = 1 == 2\ntest "good" = 1 == 1\n')
  vim.cmd.edit(file)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(at_cursor_run)
  restore()
  assert(ok, err)
  assert(#vim.fn.getqflist() == 0, 'the bad test ran: ' .. vim.inspect(vim.fn.getqflist()))
  assert(last_msg(msgs):find('1 passed, 0 failed', 1, true), vim.inspect(msgs))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  msgs, restore = H.capture_notify()
  ok, err = pcall(at_cursor_run)
  restore()
  assert(ok, err)
  assert(#vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].text:find('bad (1)', 1, true), vim.inspect(vim.fn.getqflist()))
  assert(last_msg(msgs):find('0 passed, 1 failed', 1, true), vim.inspect(msgs))
end)

test('test: <leader>aT selects a name with regexp metacharacters and quotes, in a nested module', function()
  local app = H.new_app()
  local file = app .. '/app/Todos/Index.alder'
  vim.fn.mkdir(app .. '/app/Todos', 'p')
  H.write(file, 'module Todos.Index\n\ntest "a (b) \\"c\\"" = 1 == 2\ntest "a (b) c" = 1 == 1\ntest "plain" = 1 == 1\n')
  vim.cmd.edit(file)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(at_cursor_run)
  restore()
  assert(ok, err)
  local qf = vim.fn.getqflist()
  assert(#qf == 1 and qf[1].text:find('a (b) \\"c\\"', 1, true), vim.inspect(qf))
  assert(last_msg(msgs):find('0 passed, 1 failed', 1, true), vim.inspect(msgs))
  vim.cmd('cclose') -- the failure opened the list and took focus
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  msgs, restore = H.capture_notify()
  ok, err = pcall(at_cursor_run)
  restore()
  assert(ok, err)
  assert(#vim.fn.getqflist() == 0 and last_msg(msgs):find('1 passed, 0 failed', 1, true), vim.inspect(msgs))
end)
