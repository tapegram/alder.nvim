local H = require('helpers')
local T = require('alder.test')

test('mutate: a survivor becomes a warning entry at the mutated expression', function()
  local e = T.survivor('/app', { id = 3, module = 'Todo', file = 'app/Todo.alder', decl = 'matches', line = 21, col = 14,
    kind = 'not dropped', before = 'not todo.done', after = 'todo.done', killed = false })
  assert(e.filename == '/app/app/Todo.alder' and e.lnum == 21 and e.col == 14 and e.type == 'W', vim.inspect(e))
  assert(e.text == 'survived  not dropped: not todo.done → todo.done', e.text)
  assert(T.survivor('/app', { killed = true, file = 'app/Todo.alder', line = 1, col = 1 }) == nil)
end)

test('mutate: the title carries the score', function()
  assert(T.mutate_title({ score = 0.5625, killed = 18, survived = 14, suppressed = 0, skipped = 0 })
    == 'alder test --mutate — 18 killed, 14 survived (0.56)')
end)

-- The real shape: one {"mutants":[...]} object, then the score object. `-run '^Demo '` runs only
-- Demo's test (a placeholder: `40 + 1` itself yields no mutant) against the scaffold's mutants, so the Home mutants survive (and the run is ~1s).
test('mutate: a survivor lands in quickfix at its expression', function()
  local app = H.new_app()
  H.write(app .. '/app/Demo.alder', 'module Demo\n\nanswer : Int\nanswer = 40 + 1\n\ntest "answer is positive" = answer > 0\n')
  local done = false
  T.mutate(app, { args = { '-run', '^Demo ' }, on_done = function() done = true end })
  assert(H.wait(300000, function() return done end), 'alder test --mutate did not finish')
  local qf = vim.fn.getqflist({ title = 0, items = 0 })
  assert(vim.startswith(qf.title, 'alder test --mutate'), qf.title)
  local hit
  for _, it in ipairs(qf.items) do
    if it.text:find('survived', 1, true) and vim.api.nvim_buf_get_name(it.bufnr):find('Home.alder', 1, true) then hit = it end
  end
  assert(hit and hit.lnum > 0 and hit.type == 'W', vim.inspect(qf.items))
end)

test('mutate: says it is running; a second run cancels the first with a WARN; test runs are independent', function()
  local app = H.new_app()
  local msgs, restore = H.capture_notify()
  local first, second = false, false
  local ok, err = pcall(function()
    T.mutate(app, { args = { '-run', '^Demo ' }, on_done = function() first = true end })
    T.mutate(app, { args = { '-run', '^Demo ' }, on_done = function() second = true end })
    -- a test run for the same app must not cancel the mutate run
    T.run(app, {})
    assert(H.wait(300000, function() return second end), 'the second mutate run did not finish')
  end)
  restore()
  assert(ok, err)
  assert(not first, 'the cancelled run must not report')
  local running, cancelled, test_cancel = 0, false, false
  for _, m in ipairs(msgs) do
    if m.msg == 'alder test --mutate: running…' then running = running + 1 end
    if m.msg == 'alder test --mutate: the earlier run was cancelled' and m.level == vim.log.levels.WARN then cancelled = true end
    if m.msg:find('alder test: the earlier run', 1, true) then test_cancel = true end
  end
  assert(running == 2 and cancelled and not test_cancel, vim.inspect(msgs))
end)
