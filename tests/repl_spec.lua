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
