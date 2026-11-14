local picker = require('alder.picker')

local items = {
  { id = 'new action', summary = 'a message and its update arm', here = true },
  { id = 'new form', summary = 'a form, its message and arm', here = true },
  { id = 'new route', summary = 'a route module' },
  { id = 'edit table', summary = 'change a table' },
}

test('picker: an empty query keeps every item in order', function()
  local got = picker.filter(items, '')
  assert(#got == 4 and got[1].id == 'new action' and got[4].id == 'edit table', vim.inspect(got))
  assert(got ~= items, 'filter must return a copy')
end)

test('picker: fuzzy on id and summary', function()
  local got = picker.filter(items, 'tbl')
  assert(#got == 1 and got[1].id == 'edit table', vim.inspect(got))
  got = picker.filter(items, 'route')
  assert(got[1].id == 'new route', vim.inspect(got))
  assert(#picker.filter(items, 'zzzz') == 0)
end)

test('picker: lines align summaries and mark the groups', function()
  local lines, marks, headings = picker.lines(items, true)
  assert(lines[1] == 'new action  a message and its update arm', vim.inspect(lines))
  assert(lines[4] == 'edit table  change a table', vim.inspect(lines))
  assert(marks[1].row == 1 and marks[1].col == #'new action  ' and marks[1].hl == 'Comment', vim.inspect(marks))
  assert(#headings == 2 and headings[1].row == 1 and headings[1].text == '── here ──', vim.inspect(headings))
  assert(headings[2].row == 3 and headings[2].text == '── all ──', vim.inspect(headings))
  local _, _, none = picker.lines(items, false)
  assert(#none == 0)
  local empty = picker.lines({}, true)
  assert(#empty == 0)
end)

-- ── The window ───────────────────────────────────────────────────────────────

local H = require('helpers')

local fruits = {
  { name = 'apple', sig = 'Fruit -> Red' },
  { name = 'banana', sig = 'Fruit -> Yellow' },
  { name = 'cherry', sig = 'Fruit -> Red' },
}

local function row(it) return it.name, it.sig end

local function floats()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then n = n + 1 end
  end
  return n
end

-- async_source records every fetch; answer(i, items, note) replies to the i-th one.
local function async_source()
  local calls = {}
  return {
    calls = calls,
    fetch = function(q, done) calls[#calls + 1] = { q = q, done = done } end,
  }
end

test('picker: local source filters and confirms', function()
  local picked, closed
  local p = picker.open({ title = 'Fruit', row = row,
    source = { items = fruits, filter = function(items, q) return picker.filter(items, q, function(it) return it.name end) end },
    on_pick = function(it) picked = it end, on_close = function() closed = true end })
  local ok, err = pcall(function()
    local text = H.float_text()
    assert(text:find('apple +Fruit %-> Red'), text)
    assert(text:find('banana', 1, true) and text:find('cherry', 1, true), text)
    p:set_query('ban')
    text = H.float_text()
    assert(text:find('banana', 1, true) and not text:find('apple', 1, true), text)
    assert(p:selected().name == 'banana')
    p:confirm()
    assert(picked and picked.name == 'banana', vim.inspect(picked))
    assert(closed, 'on_close not called')
    assert(floats() == 0, 'windows left open')
  end)
  p:close()
  assert(ok, err)
end)

test('picker: async source replaces the list', function()
  local src = async_source()
  local p = picker.open({ title = 'Search', row = row, hint = 'try: apple', source = src })
  local ok, err = pcall(function()
    assert(H.wait(1000, function() return #src.calls == 1 end), 'no fetch on open')
    src.calls[1].done({})
    assert(H.float_text():find('try: apple', 1, true), H.float_text())
    p:set_query('red')
    assert(H.wait(1000, function() return #src.calls == 2 end), 'no fetch after set_query')
    assert(src.calls[2].q == 'red', src.calls[2].q)
    src.calls[2].done({ fruits[1], fruits[3] })
    local text = H.float_text()
    assert(text:find('apple', 1, true) and text:find('cherry', 1, true) and not text:find('banana', 1, true), text)
    p:set_query('zzz')
    assert(H.wait(1000, function() return #src.calls == 3 end), 'no fetch after set_query')
    src.calls[3].done({}, 'nothing matches zzz')
    text = H.float_text()
    assert(text:find('nothing matches zzz', 1, true) and not text:find('apple', 1, true), text)
  end)
  p:close()
  assert(ok, err)
end)

test('picker: a stale fetch reply is dropped', function()
  local src = async_source()
  local p = picker.open({ title = 'Search', row = row, source = src })
  local ok, err = pcall(function()
    assert(H.wait(1000, function() return #src.calls == 1 end), 'no fetch on open')
    p:set_query('a')
    assert(H.wait(1000, function() return #src.calls == 2 end), 'no fetch for a')
    p:set_query('b')
    assert(H.wait(1000, function() return #src.calls == 3 end), 'no fetch for b')
    src.calls[3].done({ fruits[2] })
    src.calls[2].done({ fruits[1] })
    src.calls[1].done({ fruits[3] })
    local text = H.float_text()
    assert(text:find('banana', 1, true) and not text:find('apple', 1, true) and not text:find('cherry', 1, true), text)
  end)
  p:close()
  assert(ok, err)
end)

test('picker: detail pane shows the selected item and follows move', function()
  local p = picker.open({ title = 'Fruit', row = row, source = { items = fruits, filter = picker.filter },
    detail = function(it) return { 'about ' .. it.name, it.sig }, { { row = 1, col = 0, end_col = 5, hl = 'Title' } } end })
  local ok, err = pcall(function()
    local text = H.float_text()
    assert(text:find('about apple', 1, true) and not text:find('about banana', 1, true), text)
    p:move(1)
    text = H.float_text()
    assert(text:find('about banana', 1, true) and not text:find('about apple', 1, true), text)
    p:move(-2)
    assert(H.float_text():find('about cherry', 1, true), H.float_text())
  end)
  p:close()
  assert(ok, err)
end)

test('picker: Esc restores window, cursor and mode', function()
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two three', 'four' })
  vim.api.nvim_win_set_cursor(0, { 2, 4 })
  local win = vim.api.nvim_get_current_win()
  local closed
  picker.open({ title = 'Fruit', row = row, source = { items = fruits, filter = picker.filter },
    on_close = function() closed = true end })
  assert(vim.api.nvim_get_current_win() ~= win, 'picker did not take focus')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  H.wait(200, function() return false end)
  assert(closed, 'on_close not called')
  assert(floats() == 0, 'windows left open')
  assert(vim.api.nvim_get_current_win() == win)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), { 2, 4 }), vim.inspect(vim.api.nvim_win_get_cursor(win)))
  assert(vim.api.nvim_get_mode().mode == 'n', vim.api.nvim_get_mode().mode)
end)

test('picker: extra keys get the selected item', function()
  local got
  local p = picker.open({ title = 'Fruit', row = row, source = { items = fruits, filter = picker.filter },
    keys = { ['<C-]>'] = function(it) got = it end } })
  local ok, err = pcall(function()
    p:move(1)
    vim.api.nvim_feedkeys(vim.keycode('<C-]>'), 'x', false)
    assert(got and got.name == 'banana', vim.inspect(got))
  end)
  p:close()
  assert(ok, err)
end)

test('picker: a throwing on_pick is reported and the picker still settles', function()
  local p = picker.open({ title = 'Fruit', row = row, source = { items = fruits },
    on_pick = function() error('boom') end })
  local settled = false
  p.settle = function() settled = true end
  local messages, restore = H.capture_notify()
  local ok, err = pcall(function() p:confirm() end)
  restore()
  p:close()
  assert(ok, err)
  assert(settled, 'settle not run')
  assert(#messages == 1 and messages[1].msg:find('boom', 1, true) and messages[1].level == vim.log.levels.ERROR,
    vim.inspect(messages))
end)
