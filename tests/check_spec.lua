local H = require('helpers')
local check = require('alder.check')

-- the E0102 corpus case from the alder repo: one diagnostic with a fix
local function fixture(parent)
  local app = (parent or H.tmpdir()) .. '/e0102'
  H.copy_tree(H.alder_repo() .. '/testdata/corpus/E0102-maybe-field', app)
  local expected = H.read(app .. '/expected.diag')
  local file = expected:match('(app/[%w/]+%.alder):%d+:%d+ E0102')
  assert(file, 'no E0102 line in expected.diag:\n' .. expected)
  return app, file
end

local function diags(buf, code)
  return vim.tbl_filter(function(d) return code == nil or d.code == code end,
    vim.diagnostic.get(buf, { namespace = check.ns }))
end

-- run_check runs check.run and waits for it to report.
local function run_check(app, o)
  o = o or {}
  local done = false
  o.on_done = function() done = true end
  check.run(app, o)
  assert(H.wait(20000, function() return done end), 'alder check did not finish')
end

test('check: 1-based byte columns become 0-based, ends exclusive', function()
  local d = check.to_diagnostic({ code = 'E0001', severity = 'warning', file = 'app/A.alder', line = 3, col = 5,
    endLine = 4, endCol = 2, message = 'm', fix = { line = 3, col = 5, endLine = 3, endCol = 6, replace = 'x' } })
  assert(d.lnum == 2 and d.col == 4 and d.end_lnum == 3 and d.end_col == 1, vim.inspect(d))
  assert(d.severity == vim.diagnostic.severity.WARN and d.code == 'E0001' and d.source == 'alder')
  assert(d.user_data.fix.replace == 'x')
end)

test('check: severity maps warning to WARN, anything else to ERROR', function()
  assert(check.severity('warning') == vim.diagnostic.severity.WARN)
  assert(check.severity('error') == vim.diagnostic.severity.ERROR)
  assert(check.severity(nil) == vim.diagnostic.severity.ERROR)
end)

test('check: a file not open goes to the quickfix list; an open one gets diagnostics', function()
  local app, file = fixture()
  local done = false
  check.run(app, { on_done = function() done = true end })
  assert(H.wait(20000, function() return done end), 'alder check did not finish')
  local qf = vim.fn.getqflist()
  assert(#qf >= 1 and qf[1].text:find('E0102'), vim.inspect(qf))

  vim.cmd.edit(app .. '/' .. file)
  local buf = vim.api.nvim_get_current_buf()
  done = false
  check.run(app, { on_done = function() done = true end })
  assert(H.wait(20000, function() return done end))
  assert(#diags(buf, 'E0102') == 1, vim.inspect(diags(buf)))
  for _, item in ipairs(vim.fn.getqflist()) do
    assert(not item.text:find('E0102'), 'an open file is still in the quickfix list')
  end
end)

-- Ruling S6: check never clobbers a quickfix list it did not make.
test('check: the user\'s quickfix list is kept; alder check replaces only its own', function()
  local app = fixture()
  vim.fn.setqflist({}, 'f')
  vim.fn.setqflist({}, ' ', { title = 'mine', items = { { filename = 'x', lnum = 1, text = 'keep me' } } })
  run_check(app)
  local cur = vim.fn.getqflist({ title = 0, nr = 0 })
  assert(cur.title == 'alder check' and cur.nr == 2, vim.inspect(cur))
  local mine = vim.fn.getqflist({ nr = 1, title = 0, items = 0 })
  assert(mine.title == 'mine' and mine.items[1].text == 'keep me', vim.inspect(mine))
  run_check(app)
  local again = vim.fn.getqflist({ title = 0, nr = '$' })
  assert(again.nr == 2 and again.title == 'alder check', 'a second check pushed another list: ' .. vim.inspect(again))
end)

-- Ruling S6 (fix round 1): a check with nothing for the quickfix list leaves the user's list
-- current; it does not push an empty one.
test('check: a check with no quickfix items leaves the user\'s list alone', function()
  local app = fixture()
  vim.fn.setqflist({}, 'f')
  vim.fn.setqflist({}, ' ', { title = 'mine', items = { { filename = 'x', lnum = 1, text = 'keep me' } } })
  local items = check.publish(app, {})
  assert(#items == 0)
  local cur = vim.fn.getqflist({ title = 0, nr = 0 })
  local last = vim.fn.getqflist({ nr = '$' }).nr
  assert(cur.title == 'mine' and cur.nr == 1 and last == 1, vim.inspect({ cur = cur, last = last }))
  -- once alder check's list is current, an empty result does replace it (clears old errors)
  check.publish(app, { { code = 'E0102', severity = 'error', file = 'app/Gone.alder', line = 1, col = 1,
    message = 'm' } })
  check.publish(app, {})
  local ours = vim.fn.getqflist({ title = 0, nr = 0, size = 0 })
  assert(ours.title == 'alder check' and ours.nr == 2 and ours.size == 0, vim.inspect(ours))
end)

-- Ruling C11: the window opens for an error in another file.
test('check: open_qf opens the quickfix window for an error in another file', function()
  local app = fixture()
  vim.cmd('cclose')
  run_check(app, { open_qf = true })
  assert(vim.fn.getqflist({ winid = 0 }).winid ~= 0, 'the quickfix window did not open')
  vim.cmd('cclose')
end)

test('fix: :AlderFix applies the fix under the cursor; saving clears the diagnostic', function()
  local app, file = fixture()
  vim.cmd.edit(app .. '/' .. file)
  local buf = vim.api.nvim_get_current_buf()
  local done = false
  check.run(app, { on_done = function() done = true end })
  assert(H.wait(20000, function() return done end))
  local d = assert(diags(buf, 'E0102')[1], 'no E0102')
  vim.api.nvim_win_set_cursor(0, { d.lnum + 1, d.col })
  assert(check.fix_at_cursor(), 'no fix applied')
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(text:find('(match user { Just x -> x.name, Nothing -> ?default }) }', 1, true), text)
  vim.cmd('silent write') -- BufWritePost runs alder check (check_on_save)
  -- Review Focus 3: the fixed file loses its diagnostic
  assert(H.wait(20000, function() return #diags(buf, 'E0102') == 0 end), vim.inspect(diags(buf)))
end)

-- Review Focus 3: a superseded run must not publish late.
test('check: a newer run supersedes an older one', function()
  local app, file = fixture()
  vim.cmd.edit(app .. '/' .. file)
  local buf = vim.api.nvim_get_current_buf()
  local first, second = false, false
  check.run(app, { on_done = function() first = true end })
  check.run(app, { on_done = function() second = true end })
  assert(H.wait(20000, function() return second end), 'the second run did not finish')
  vim.wait(500)
  assert(not first, 'the superseded run still reported')
  assert(#diags(buf, 'E0102') == 1)
end)

-- Review Focus 3: a superseded run's result that arrives after the newer one's is dropped,
-- also when the two runs name the same app by different paths. The CLI is stubbed so the
-- results can arrive out of order.
test('check: a late superseded result does not overwrite the newer one', function()
  local app, file = fixture()
  local link = H.tmpdir() .. '/link'
  assert(vim.uv.fs_symlink(app, link))
  vim.cmd.edit(app .. '/' .. file)
  local buf = vim.api.nvim_get_current_buf()
  local cli = require('alder.cli')
  local orig, pending = cli.run, {}
  cli.run = function(_, _, on_done)
    table.insert(pending, on_done)
    return { kill = function() end }
  end
  vim.diagnostic.set(check.ns, buf, { check.to_diagnostic({ code = 'E0102', line = 12, col = 25, message = 'old' }) })
  local first, second = false, false
  local ok, err = pcall(function()
    check.run(link, { on_done = function() first = true end })
    check.run(app, { on_done = function() second = true end })
    local stale = { code = 'E0102', severity = 'error', file = file, line = 12, col = 25, endLine = 12, endCol = 34,
      message = 'stale' }
    pending[2]({ code = 0, stdout = '', stderr = '', objects = {} }) -- the newer run: file fixed
    pending[1]({ code = 1, stdout = '', stderr = '', objects = { stale }, json = stale }) -- the late one
  end)
  cli.run = orig
  assert(ok, err)
  assert(second and not first, 'the superseded run still reported')
  assert(#diags(buf) == 0, vim.inspect(diags(buf)))
end)

-- Review Focus 4: the buffer is opened through a symlink; the CLI reports the real path.
test('check: diagnostics reach a buffer opened through a symlink', function()
  local app, file = fixture()
  local link = H.tmpdir() .. '/link'
  assert(vim.uv.fs_symlink(app, link))
  vim.cmd.edit(link .. '/' .. file)
  local buf = vim.api.nvim_get_current_buf()
  local done = false
  check.run(require('alder.root').for_buf(buf), { on_done = function() done = true end })
  assert(H.wait(20000, function() return done end))
  assert(#diags(buf, 'E0102') == 1, vim.inspect(diags(buf)))
end)

-- Review Focus 4: on macOS /tmp is a symlink to /private/tmp. A buffer opened as /tmp/… gets
-- the diagnostics of a check run on the /private/tmp/… path (and on the /tmp/… one).
test('check: a buffer opened via /tmp gets diagnostics reported for /private/tmp', function()
  local dir = '/tmp/alder-nvim-' .. vim.fn.fnamemodify(vim.fn.tempname(), ':t')
  vim.fn.mkdir(dir, 'p')
  local ok, err = pcall(function()
    local app, file = fixture(dir)
    vim.cmd.edit(app .. '/' .. file)
    local buf = vim.api.nvim_get_current_buf()
    -- the CLI is given each spelling of the root; the buffer gets the diagnostic either way
    for _, r in ipairs({ vim.uv.fs_realpath(app), app }) do -- /private/tmp/… on macOS, then /tmp/…
      vim.diagnostic.reset(check.ns, buf)
      run_check(r)
      assert(#diags(buf, 'E0102') == 1, r .. ': ' .. vim.inspect(diags(buf)))
    end
  end)
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(dir, 'rf')
  assert(ok, err)
end)

-- Review Focus 5: byte columns after multi-byte characters.
test('fix: byte columns after multi-byte text', function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = "é→" ++ nmae' })
  -- `nmae` starts at byte 16 (1-based): "é" is 2 bytes and "→" 3
  local ok = check.apply_fix(buf, { line = 1, col = 16, endLine = 1, endCol = 20, replace = 'name' })
  assert(ok)
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'x = "é→" ++ name')
end)

-- Review Focus 5: the same through a diagnostic and :AlderFix, cursor after the multi-byte text.
test('fix: :AlderFix after multi-byte text lands on the right bytes', function()
  local file = H.tmpdir() .. '/M.alder'
  H.write(file, 'x = "é→" ++ nmae\n')
  vim.cmd.edit(file)
  local buf = vim.api.nvim_get_current_buf()
  local d = check.to_diagnostic({ code = 'E0001', severity = 'error', line = 1, col = 16, endLine = 1, endCol = 20,
    message = 'm', fix = { line = 1, col = 16, endLine = 1, endCol = 20, replace = 'name' } })
  vim.diagnostic.set(check.ns, buf, { d })
  vim.b[buf].alder_check_tick = vim.api.nvim_buf_get_changedtick(buf) -- as publish records it
  vim.api.nvim_win_set_cursor(0, { 1, 16 }) -- 0-based byte 16 is the `m` of `nmae`
  vim.cmd('AlderFix')
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'x = "é→" ++ name',
    vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
end)

-- Fix round 1: positions are as of the last check. After an edit (a line inserted above the
-- diagnostic) :AlderFix refuses instead of overwriting the wrong bytes.
test('fix: :AlderFix refuses after the buffer changed since the check', function()
  local app, file = fixture()
  vim.cmd.edit(app .. '/' .. file)
  local buf = vim.api.nvim_get_current_buf()
  run_check(app)
  assert(diags(buf, 'E0102')[1], 'no E0102')
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '-- a new first line' })
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local d = diags(buf, 'E0102')[1] -- its extmark moved down a line; the fix's range did not
  vim.api.nvim_win_set_cursor(0, { d.lnum + 1, d.col })
  local messages, restore = H.capture_notify()
  local ok = pcall(vim.cmd, 'AlderFix')
  restore()
  assert(ok)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before), 'the buffer changed')
  assert(messages[1] and messages[1].msg == 'alder: the fix no longer matches the buffer; save to re-check',
    vim.inspect(messages))
end)

test('fix: a stale fix is refused, not applied elsewhere', function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'short' })
  local ok, err = check.apply_fix(buf, { line = 4, col = 1, endLine = 4, endCol = 3, replace = 'x' })
  assert(not ok and err:find('save to re%-check'), tostring(err))
end)

-- Ruling C8: the float holds the compiler's text, not just any window.
test('explain: the compiler text in a float', function()
  local r = vim.system({ 'alder', 'explain', 'E0102' }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
  local first = vim.split(vim.trim(r.stdout), '\n', { plain = true })[1]
  local before = #vim.api.nvim_list_wins()
  check.explain('E0102')
  assert(H.wait(10000, function() return #vim.api.nvim_list_wins() > before end), 'no float opened')
  local found = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
      for _, l in ipairs(lines) do
        if l == first then found = true end
      end
      vim.api.nvim_win_close(win, true)
    end
  end
  assert(found, 'the float does not hold: ' .. first)
end)

test('errors: no app root is said once, plainly', function()
  local messages, restore = H.capture_notify()
  local dir = H.tmpdir()
  H.write(dir .. '/Stray.alder', 'module Stray\n')
  vim.cmd.edit(dir .. '/Stray.alder')
  vim.cmd('AlderCheck')
  restore()
  assert(messages[1] and messages[1].msg == 'alder: no `app/` directory above this file', vim.inspect(messages))
end)
