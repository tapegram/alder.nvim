local H = require('helpers')
local R = require('alder.repl')

local function text_of(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end

-- stop ends a session's job and waits for it, so no REPL outlives its test.
local function stop(s)
  if s and s.job then
    vim.fn.jobstop(s.job)
    vim.fn.jobwait({ s.job }, 5000)
  end
end

test('repl: argv adds --in for a module and nothing without one', function()
  assert(vim.deep_equal(R.argv('/app', 'Todo'), { 'alder', 'repl', '--in', 'Todo' }), vim.inspect(R.argv('/app', 'Todo')))
  assert(vim.deep_equal(R.argv('/app', 'Todos.Index'), { 'alder', 'repl', '--in', 'Todos.Index' }))
  assert(vim.deep_equal(R.argv('/app', nil), { 'alder', 'repl' }))
end)

test('repl: join strips the common indent and continues lines with a backslash', function()
  assert(R.join({ '    xs', '      |> List.map f' }) == 'xs \\\n  |> List.map f\n', vim.inspect(R.join({ '    xs', '      |> List.map f' })))
  assert(R.join({ 'x' }) == 'x\n')
  assert(R.join({ '  a', '', '  b' }) == 'a \\\n \\\nb\n')
end)

local function wait_banner(s)
  return H.wait(30000, function() return s.ready end)
end

-- shows waits for text in the terminal buffer, which renders a little after on_stdout fires.
local function shows(s, text)
  return H.wait(10000, function() return text_of(s.buf):find(text, 1, true) ~= nil end)
end

test('repl: open starts alder repl --in in a terminal split, and a second open reuses it', function()
  local app = H.new_app()
  local s = R.open(app, 'App')
  local ok, err = pcall(function()
    assert(s and s.job and s.buf, 'no session')
    assert(vim.bo[s.buf].buftype == 'terminal')
    assert(wait_banner(s), 'no banner: ' .. text_of(s.buf))
    assert(shows(s, 'alder repl: demo, in App'), text_of(s.buf))
    local again = R.open(app, 'Other')
    assert(again.job == s.job, 'a second open started a new REPL')
  end)
  stop(s)
  assert(ok, err)
end)

test('repl: send before the banner is queued, not lost', function()
  local app = H.new_app()
  local s = R.open(app, nil)
  local ok, err = pcall(function()
    R.send(app, '1 + 2\n')
    assert(not s.ready, 'the banner came before the send: the test proves nothing')
    -- held back, not written to the job yet (a pty may buffer early input, but nothing promises it)
    assert(vim.deep_equal(s.queue, { '1 + 2\n' }), vim.inspect(s.queue))
    assert(wait_banner(s), 'no banner')
    -- flushed as the banner arrived, so nothing sent after ready can overtake it
    assert(#s.queue == 0, vim.inspect(s.queue))
    assert(H.wait(60000, function() return text_of(s.buf):find('3 : Int', 1, true) ~= nil end), text_of(s.buf))
  end)
  stop(s)
  assert(ok, err)
end)

test('repl: send_current with no REPL opens one in the buffer\'s module and sends the line', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  local src = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { '  20 + 22' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  R.send_current('n')
  local s = R.sessions[require('alder.root').real(app)]
  local ok, err = pcall(function()
    assert(s and s.buf, 'no REPL started')
    assert(vim.api.nvim_get_current_win() == src, 'focus left the source window')
    assert(wait_banner(s), 'no banner: ' .. text_of(s.buf))
    assert(shows(s, 'alder repl: demo, in App'), text_of(s.buf))
    assert(H.wait(60000, function() return text_of(s.buf):find('42 : Int', 1, true) ~= nil end), text_of(s.buf))
  end)
  stop(s)
  assert(ok, err)
end)

test('repl: send_current in visual mode sends the selected lines as one entry', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { '    1', '      + 41' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local sent
  local orig = R.send
  R.send = function(_, text) sent = text end
  local ok, err = pcall(function()
    vim.cmd('normal! Vj')
    R.send_current('x')
  end)
  R.send = orig
  assert(ok, err)
  assert(sent == '1 \\\n  + 41\n', vim.inspect(sent))
end)

test('repl: the banner is only the real one, in each scope', function()
  assert(R.banner('Todo') == ', in Todo (:help for the commands')
  assert(R.banner(nil) == ' (:help for the commands')
  local real = 'alder repl: todos, in Todo (:help for the commands, :quit to leave)'
  assert(real:find(R.banner('Todo'), 1, true))
  assert(('alder repl: todos (:help for the commands, :quit to leave)'):find(R.banner(nil), 1, true))
  for _, line in ipairs({ 'alder repl: no module Nope in /x/app', 'alder repl: the app has errors; fix them' }) do
    assert(not line:find(R.banner('Nope'), 1, true) and not line:find(R.banner(nil), 1, true), line)
  end
end)

test('repl: a REPL that exits before its banner is never ready, and queued text is said not sent', function()
  local app = H.new_app()
  local msgs, restore = H.capture_notify()
  local s
  local ok, err = pcall(function()
    s = R.open(app, 'Nope')
    assert(s, 'no session')
    R.send(app, '1 + 2\n')
    assert(H.wait(30000, function() return vim.fn.jobwait({ s.job }, 0)[1] ~= -1 end), 'the REPL did not exit')
    assert(H.wait(5000, function()
      for _, m in ipairs(msgs) do
        if m.msg:find('exited before it was ready; 1 entry not sent', 1, true) then return true end
      end
    end), vim.inspect(msgs))
    assert(not s.ready, 'a startup error line was taken for the banner')
    assert(text_of(s.buf):find('no module Nope', 1, true), text_of(s.buf))
  end)
  restore()
  stop(s)
  assert(ok, err)
end)

test('repl: send to a running REPL whose window was closed shows it again, focus kept', function()
  local app = H.new_app()
  local src = vim.api.nvim_get_current_win()
  local s = R.open(app, 'App')
  local ok, err = pcall(function()
    assert(wait_banner(s), 'no banner: ' .. text_of(s.buf))
    vim.api.nvim_win_close(vim.fn.bufwinid(s.buf), true)
    vim.api.nvim_set_current_win(src)
    assert(vim.fn.bufwinid(s.buf) == -1, 'the window is still there')
    R.send(app, '20 + 22\n')
    assert(vim.fn.bufwinid(s.buf) ~= -1, 'send did not show the REPL')
    assert(vim.api.nvim_get_current_win() == src, 'send took the focus')
    assert(vim.api.nvim_get_mode().mode == 'n', vim.inspect(vim.api.nvim_get_mode()))
    assert(H.wait(60000, function() return text_of(s.buf):find('42 : Int', 1, true) ~= nil end), text_of(s.buf))
  end)
  stop(s)
  assert(ok, err)
end)

-- fake installs a session for app on a job that ignores its input, and returns it.
local function fake(app, o)
  local job = vim.fn.jobstart({ 'sleep', '30' })
  local s = vim.tbl_extend('force', { job = job, buf = vim.api.nvim_create_buf(false, true), ready = true, queue = {} }, o or {})
  R.sessions[require('alder.root').real(app)] = s
  return s
end

-- drop ends a fake session: its job, its buffer (and any window send opened on it), its entry.
local function drop(app, s)
  stop(s)
  pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  R.sessions[require('alder.root').real(app)] = nil
end

test('repl: a send while queued text waits goes behind it, not ahead', function()
  local app = H.new_app()
  local s = fake(app, { queue = { 'first\n' } })
  R.send(app, 'second\n')
  local queue = vim.deepcopy(s.queue)
  drop(app, s)
  assert(vim.deep_equal(queue, { 'first\n', 'second\n' }), vim.inspect(queue))
end)

test('repl: a send the job cannot take is a notice, not E900', function()
  local app = H.new_app()
  local s = fake(app)
  vim.fn.chanclose(s.job, 'stdin')
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(R.send, app, '1 + 2\n')
  restore()
  drop(app, s)
  assert(ok, err)
  assert(#msgs == 1 and msgs[1].msg:find('not sent: 1 + 2', 1, true) and msgs[1].level == vim.log.levels.WARN, vim.inspect(msgs))
end)

test('repl: with no alder binary, module_for_buf does not warn about --in', function()
  local app = H.new_app()
  vim.cmd.edit(app .. '/app/App.alder')
  local opts = require('alder.config').options
  local cmd = opts.cmd
  opts.cmd = 'alder-not-installed'
  -- with no binary there is no tree, so has_flag is false (the session's tree may be cached)
  local commands = require('alder.commands')
  local has_flag = commands.has_flag
  commands.has_flag = function() return false end
  local msgs, restore = H.capture_notify()
  local ok, module = pcall(R.module_for_buf, vim.api.nvim_get_current_buf())
  restore()
  commands.has_flag = has_flag
  opts.cmd = cmd
  vim.cmd('bwipeout!')
  assert(ok, module)
  assert(module == 'App', vim.inspect(module))
  assert(#msgs == 0, vim.inspect(msgs))
end)

test('repl: AlderRepl warns deprecated', function()
  local called = false
  local orig = R.for_current
  R.for_current = function() called = true end
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(vim.cmd, 'AlderRepl')
  restore()
  R.for_current = orig
  assert(ok, err)
  assert(called)
  assert(#msgs == 1 and msgs[1].level == vim.log.levels.WARN, vim.inspect(msgs))
  assert(msgs[1].msg == 'alder repl is deprecated: use a scratch file (alder scratch --watch, or save scratch.alder in the editor); it will be removed in the next release', msgs[1].msg)
end)
