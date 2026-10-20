local cli = require('alder.cli')
local check = require('alder.check')
local root = require('alder.root')

local M = {}

M.QF_TITLE = 'alder test'

local real = root.real

local function flat(s) return (s:gsub('%s*\n%s*', ' ')) end

-- entry maps one `alder test --json` result to a quickfix item, or nil for a pass. A result
-- without a position (a crashed program's) keeps the module in the text and lnum 0.
function M.entry(app_root, r)
  if r.ok then return nil end
  local what
  if r.left or r.right then
    what = 'left: ' .. flat(r.left or '') .. '  right: ' .. flat(r.right or '')
  elseif r.error then
    what = 'error: ' .. flat(r.error)
  elseif r.note then
    what = 'note: ' .. flat(r.note)
  else
    what = 'failed'
  end
  local positioned = r.file and r.line and r.line > 0
  local name = positioned and ('"' .. r.name .. '"') or (r.module .. ' "' .. r.name .. '"')
  return {
    filename = positioned and (app_root .. '/' .. r.file) or nil,
    lnum = positioned and r.line or 0,
    col = positioned and (r.col or 1) or 0,
    type = 'E',
    text = 'FAIL ' .. name .. ' — ' .. what,
  }
end

-- summary is the CLI's closing line, from the results.
function M.summary(results)
  local passed, failed = 0, 0
  for _, r in ipairs(results) do
    if r.ok then passed = passed + 1 else failed = failed + 1 end
  end
  return ('%d passed, %d failed'):format(passed, failed)
end

-- write_app_buffers writes every modified .alder buffer under app_root (the run reads disk)
-- and returns the names of those it could not write.
-- It is a normal write, so BufWritePost (and the LSP's didSave) fire; that means an
-- `alder check` from the BufWritePost hook may run concurrently with the test run and publish
-- its diagnostics around the same time. They are the same source, so that is harmless.
function M.write_app_buffers(app_root)
  local app_real, failed = real(app_root), {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and name:match('%.alder$') then
      local r = root.find(name)
      if r and real(r) == app_real then
        local ok = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent write') end)
        if not ok or vim.bo[buf].modified then table.insert(failed, vim.fn.fnamemodify(name, ':.')) end
      end
    end
  end
  return failed
end

-- results_of are the test objects of a run: those with a `name` (the diagnostics and error
-- objects have none).
local function results_of(objects)
  return vim.tbl_filter(function(o) return o.name ~= nil end, objects)
end

-- warn_positions warns once when a failed result has no `line` at all (an alder that predates
-- positions; line 0 is the CLI's own "no position"), so the list is not silently unpositioned.
function M.warn_positions(_, results)
  for _, r in ipairs(results) do
    if not r.ok and r.line == nil then
      vim.notify('alder test: failures carry no position (this alder predates `alder test --json` positions); update alder',
        vim.log.levels.WARN)
      return
    end
  end
end

local runs = {} -- real app root + label → the latest launch { handle }

-- launch is the shared start of a CLI run for an app (tests, mutants): a newer launch with the
-- same label for the same app cancels the older one (WARN), whose result is then dropped. Test
-- and mutate runs are independent (they build in separate directories, so they may overlap); modified app buffers are
-- written first (WARN for those that could not be); `alder <args> <app_root>` runs from the
-- app root and on_done(res) gets the result. label prefixes the notifications. Returns the
-- system handle (nil when the binary is missing).
function M.launch(app_root, label, args, on_done)
  local key = real(app_root) .. '\0' .. label
  local prev = runs[key]
  if prev and prev.handle then
    pcall(function() prev.handle:kill('sigterm') end)
    vim.notify(label .. ': the earlier run was cancelled', vim.log.levels.WARN)
  end
  local unwritten = M.write_app_buffers(app_root)
  if #unwritten > 0 then
    vim.notify(label .. ': not written, the run reads disk: ' .. table.concat(unwritten, ', '), vim.log.levels.WARN)
  end
  local mine = {}
  runs[key] = mine
  local full = vim.list_extend({}, args)
  table.insert(full, app_root)
  mine.handle = cli.run(full, { cwd = app_root }, function(res)
    if runs[key] ~= mine then return end
    runs[key] = nil
    on_done(res, full)
  end)
  if not mine.handle and runs[key] == mine then runs[key] = nil end
  return mine.handle
end

-- compile_failed handles a run whose app does not check (diagnostics instead of results):
-- publishes them as check does and opens the list on an error. Returns true when it did.
function M.compile_failed(app_root, label, res)
  if not (res.json and res.json.diagnostics) then return false end
  local items = check.publish(app_root, res.json.diagnostics)
  vim.notify(label .. ': the app does not check', vim.log.levels.ERROR)
  for _, item in ipairs(items) do
    if item.type == 'E' then vim.cmd('copen') break end
  end
  return true
end

-- run runs `alder test --json <o.args>` for the app and reports: compile diagnostics through
-- check.publish, failures in the quickfix list, the summary as a notification.
function M.run(app_root, o)
  o = o or {}
  local args = { 'test', '--json' }
  vim.list_extend(args, o.args or {})
  local function done(res) if o.on_done then o.on_done(res) end end
  M.launch(app_root, 'alder test', args, function(res, full)
    if M.compile_failed(app_root, 'alder test', res) then return done(res) end
    local results = results_of(res.objects)
    if res.code == 2 or (res.code ~= 0 and #results == 0) or (res.json and res.json.error) then
      cli.report(full, res)
      return done(res)
    end
    M.warn_positions(app_root, results)
    local items = {}
    for _, r in ipairs(results) do
      local e = M.entry(app_root, r)
      if e then table.insert(items, e) end
    end
    check.set_qf(items, M.QF_TITLE)
    if #items > 0 then
      vim.cmd('copen')
      vim.notify('alder test: ' .. M.summary(results), vim.log.levels.ERROR)
    else
      if vim.fn.getqflist({ title = 0 }).title == M.QF_TITLE then vim.cmd('cclose') end
      vim.notify('alder test: ' .. M.summary(results), vim.log.levels.INFO)
    end
    done(res)
  end)
end

-- for_current runs the tests of the current buffer's app, or says there is none.
function M.for_current(o)
  local r = root.require_for_buf(0)
  if r then M.run(r, o) end
end

-- run_pattern is the -run regexp selecting one test (`^Module "name"$`) or, without a name,
-- every test of the module. name is the source text between the test's quotes, which is how
-- alder names the test (escapes included, `a \"c\"`); its Go regexp metacharacters, backslash
-- too, are escaped.
function M.run_pattern(module, name)
  if not name then return '^' .. module .. ' ' end
  local escaped = name:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?%{%}%|\\]', '\\%0')
  return '^' .. module .. ' "' .. escaped .. '"$'
end

-- at_cursor runs the test under the cursor, or the current module's tests when none is above
-- it, or the whole suite outside a module.
function M.at_cursor()
  local buf = require('alder.buf')
  local b = vim.api.nvim_get_current_buf()
  local module = buf.module_name(b)
  if not module then
    vim.notify('alder test: no `module` line in this buffer; running every test', vim.log.levels.WARN)
    return M.for_current()
  end
  local name = buf.test_at(b, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not name then
    vim.notify('alder test: no test above the cursor; running ' .. module .. "'s tests", vim.log.levels.INFO)
  end
  M.for_current({ args = { '-run', M.run_pattern(module, name) } })
end

M.MUTATE_TITLE = 'alder test --mutate'

-- survivor maps one `--mutate --json` mutant to a quickfix item, or nil when it was killed.
function M.survivor(app_root, m)
  if m.killed or not m.file then return nil end
  return {
    filename = app_root .. '/' .. m.file,
    lnum = m.line or 0,
    col = m.col or 0,
    type = 'W',
    text = ('survived  %s: %s → %s'):format(m.kind or '?', m.before or '', m.after or ''),
  }
end

-- mutate_title is the quickfix title, from the run's score object.
function M.mutate_title(s)
  return ('%s — %d killed, %d survived (%.2f)'):format(M.MUTATE_TITLE, s.killed or 0, s.survived or 0, s.score or 0)
end

-- mutate runs `alder test --mutate --json` in the background and puts the survivors in the
-- quickfix list. The output is one {"mutants":[...]} object, then the score object. A newer
-- run for the same app (test or mutate) cancels this one (see launch).
function M.mutate(app_root, o)
  o = o or {}
  local args = { 'test', '--mutate', '--json' }
  vim.list_extend(args, o.args or {})
  local function done(res) if o.on_done then o.on_done(res) end end
  vim.notify(M.MUTATE_TITLE .. ': running…', vim.log.levels.INFO)
  local started = M.launch(app_root, M.MUTATE_TITLE, args, function(res, full)
    if M.compile_failed(app_root, M.MUTATE_TITLE, res) then return done(res) end
    local score
    for _, obj in ipairs(res.objects) do
      if obj.score ~= nil and obj.killed ~= nil and obj.mutants == nil then score = obj end
    end
    if res.code == 2 or (res.json and res.json.error) or not score then
      cli.report(full, res)
      return done(res)
    end
    local items = {}
    for _, obj in ipairs(res.objects) do
      for _, m in ipairs(obj.mutants or {}) do
        local e = M.survivor(app_root, m)
        if e then table.insert(items, e) end
      end
    end
    table.sort(items, function(a, b)
      if a.filename ~= b.filename then return a.filename < b.filename end
      return a.lnum < b.lnum
    end)
    local title = M.mutate_title(score)
    -- the title changes with the score, so ours is a prefix match (check.set_qf is exact)
    local ours = vim.startswith(vim.fn.getqflist({ title = 0 }).title, M.MUTATE_TITLE)
    if #items > 0 or ours then
      vim.fn.setqflist({}, ours and 'r' or ' ', { title = title, items = items })
    end
    if #items > 0 then
      vim.cmd('copen')
      vim.notify(title, vim.log.levels.WARN)
    else
      vim.notify(title .. ': no survivors', vim.log.levels.INFO)
    end
    done(res)
  end)
  return started
end

-- mutate_for_current runs the mutants of the current buffer's app.
function M.mutate_for_current(o)
  local r = root.require_for_buf(0)
  if r then M.mutate(r, o) end
end

return M
