local H = require('helpers')
local fill = require('alder.fill')

local function scratch()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match('alder://fill/') then return b end
  end
end

local function app_with_hole()
  local app = H.new_app()
  H.write(app .. '/app/Calc.alder', 'module Calc\n\nanswer : Int\nanswer = ?value\n')
  vim.cmd.edit(app .. '/app/Calc.alder')
  vim.api.nvim_win_set_cursor(0, { 4, 10 }) -- on `?value`
  return app
end

test('fill: hole_at picks the hole under the cursor, else the only one in the file', function()
  local holes = {
    { module = 'A', decl = 'x', name = 'v', type = 'Int', file = 'app/A.alder', line = 4, col = 5 },
    { module = 'A', decl = 'y', name = 'w', type = 'Int', file = 'app/A.alder', line = 7, col = 5 },
    { module = 'B', decl = 'z', name = 'u', type = 'Int', file = 'app/B.alder', line = 2, col = 1 },
  }
  assert(fill.hole_at(holes, 'app/A.alder', 4, 6).name == 'v')
  assert(fill.hole_at(holes, 'app/A.alder', 4, 7) == nil, 'past `?v`')
  assert(fill.hole_at(holes, 'app/A.alder', 1, 1) == nil, 'two holes in the file and none under the cursor')
  assert(fill.hole_at(holes, 'app/B.alder', 9, 9).name == 'u', 'the only hole in the file')
  assert(fill.address({ module = 'A', decl = 'update', arm = 'Add', name = 'v' }) == 'A.update.Add')
end)

test('fill: a scratch headed with the hole and its type; <CR> fills it', function()
  local app = app_with_hole()
  fill.fill(false)
  assert(H.wait(20000, function() return scratch() ~= nil end), 'no scratch')
  local buf = scratch()
  assert(vim.api.nvim_buf_get_name(buf):match('alder://fill/Calc%.answer/%?value$'), vim.api.nvim_buf_get_name(buf))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == '-- ?value : Int' and lines[2] == '-- Calc.answer', vim.inspect(lines))
  vim.api.nvim_buf_set_lines(buf, 2, -1, false, { '41 + 1' })
  fill.submit(buf)
  assert(H.wait(20000, function() return (H.read(app .. '/app/Calc.alder') or ''):find('answer = 41 + 1', 1, true) end),
    H.read(app .. '/app/Calc.alder'))
  assert(H.wait(5000, function() return scratch() == nil end), 'the scratch stayed open after success')
end)

test('fill: a refusal is notified and listed in quickfix, not published; the expression stays', function()
  local app = app_with_hole()
  fill.fill(false)
  assert(H.wait(20000, function() return scratch() ~= nil end))
  local buf = scratch()
  vim.fn.setqflist({}, ' ', { title = 'user list', items = { { filename = app .. '/app/Calc.alder', lnum = 1, text = 'mine' } } })
  vim.api.nvim_buf_set_lines(buf, 2, -1, false, { '"not an Int"' })
  local messages, restore = H.capture_notify()
  fill.submit(buf)
  local ok = H.wait(20000, function() return #messages > 0 end)
  restore()
  assert(ok, 'no notify for the refusal')
  assert(messages[1].level == vim.log.levels.ERROR, vim.inspect(messages))
  local qf = vim.fn.getqflist({ title = 1, size = 1 })
  assert(qf.title == 'alder fill' and qf.size > 0, vim.inspect(qf))
  local stack = vim.fn.getqflist({ nr = '$' }).nr
  local found
  for n = 1, stack do
    if vim.fn.getqflist({ nr = n, title = 1 }).title == 'user list' then found = true end
  end
  assert(found, 'the user list left the stack')
  assert(#vim.diagnostic.get(buf) == 0, 'refusal diagnostics were set on the scratch')
  assert(#vim.diagnostic.get(buf, { namespace = require('alder.check').ns }) == 0)
  assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == '"not an Int"')
  assert(scratch() == buf, 'the scratch closed on a refusal')
  assert((H.read(app .. '/app/Calc.alder') or ''):find('?value', 1, true), 'the file changed despite the refusal')
end)

test('fill: no hole under the cursor', function()
  local app = H.new_app()
  H.write(app .. '/app/Calc.alder', 'module Calc\n\na : Int\na = ?x\n\nb : Int\nb = ?y\n')
  vim.cmd.edit(app .. '/app/Calc.alder')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local messages, restore = H.capture_notify()
  fill.fill(false)
  H.wait(20000, function() return #messages > 0 end)
  restore()
  assert(messages[1] and messages[1].msg == 'alder: no hole under the cursor', vim.inspect(messages))
end)

test('fill: two holes in one declaration get distinct scratches that coexist; reopening keeps the text', function()
  local app = H.new_app()
  H.write(app .. '/app/Calc.alder', 'module Calc\n\nsum : Int\nsum = if ?c then 1 else ?d\n')
  vim.cmd.edit(app .. '/app/Calc.alder')
  local src = vim.api.nvim_get_current_win()
  local function open_at(col)
    vim.api.nvim_set_current_win(src)
    vim.api.nvim_win_set_cursor(0, { 4, col })
    local before = #vim.api.nvim_list_bufs()
    fill.fill(false)
    assert(H.wait(20000, function() return vim.api.nvim_buf_get_name(0):match('alder://fill/') end), 'no scratch')
    return vim.api.nvim_get_current_buf(), before
  end
  local a = open_at(9)
  vim.api.nvim_buf_set_lines(a, 2, -1, false, { 'typed c' })
  local b = open_at(24)
  assert(a ~= b and vim.api.nvim_buf_is_valid(a) and vim.api.nvim_buf_is_valid(b), 'second scratch replaced the first')
  assert(vim.api.nvim_buf_get_name(a):match('/%?c$') and vim.api.nvim_buf_get_name(b):match('/%?d$'))
  assert(vim.api.nvim_buf_get_lines(a, 2, 3, false)[1] == 'typed c')
  local again = open_at(9)
  assert(again == a and vim.api.nvim_buf_get_lines(a, 2, 3, false)[1] == 'typed c', 'reopening lost the typed text')
end)
