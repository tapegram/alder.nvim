local cli = require('alder.cli')
local root = require('alder.root')

local M = {}
M.ns = vim.api.nvim_create_namespace('alder')

local QF_TITLE = 'alder check'

local real = root.real

-- severity maps a JSON `severity` to Neovim's: `warning` is WARN, anything else ERROR.
function M.severity(s)
  return s == 'warning' and vim.diagnostic.severity.WARN or vim.diagnostic.severity.ERROR
end

-- to_diagnostic maps one `alder check --json` object. Its columns are 1-based bytes with
-- exclusive ends; Neovim's are 0-based bytes.
function M.to_diagnostic(d)
  local line, col = d.line or 1, d.col or 1
  return {
    lnum = line - 1,
    col = col - 1,
    end_lnum = (d.endLine or line) - 1,
    end_col = (d.endCol or col) - 1,
    severity = M.severity(d.severity),
    message = d.message,
    code = d.code,
    source = 'alder',
    user_data = { fix = d.fix },
  }
end

-- set_qf replaces the quickfix list when the current one is ours (by title), and otherwise
-- pushes a new one, so a list the user made is never overwritten. With no items and no
-- current list of ours there is nothing to say, and the user's list stays current.
function M.set_qf(items, title)
  title = title or QF_TITLE
  local ours = vim.fn.getqflist({ title = 0 }).title == title
  if not ours and #items == 0 then return end
  vim.fn.setqflist({}, ours and 'r' or ' ', { title = title, items = items })
end

-- publish replaces the alder diagnostics of every loaded .alder buffer of the app (so a fixed
-- file loses its old ones) and puts the diagnostics of files that are not open in the
-- quickfix list. Paths are compared after resolving symlinks.
-- Each buffer's b:changedtick is recorded in b:alder_check_tick when its diagnostics are set;
-- a fix is only applied while the tick is unchanged (fix_at_cursor). `alder check` reads the
-- saved file, so a buffer with unsaved changes gets no tick: its positions are already stale.
function M.publish(app_root, objects)
  local app_real = real(app_root)
  local by_file = {}
  for _, d in ipairs(objects) do
    if d.code and d.file then
      local p = real(app_root .. '/' .. d.file)
      by_file[p] = by_file[p] or {}
      table.insert(by_file[p], d)
    end
  end
  local open = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name:match('%.alder$') then
      local r = root.find(name)
      if r and real(r) == app_real then
        local p = real(name)
        open[p] = true
        vim.diagnostic.set(M.ns, buf, vim.tbl_map(M.to_diagnostic, by_file[p] or {}))
        vim.b[buf].alder_check_tick = not vim.bo[buf].modified and vim.api.nvim_buf_get_changedtick(buf) or nil
      end
    end
  end
  local items = {}
  for p, ds in pairs(by_file) do
    if not open[p] then
      for _, d in ipairs(ds) do
        table.insert(items, { filename = p, lnum = d.line, col = d.col, end_lnum = d.endLine, end_col = d.endCol,
          text = d.code .. ' ' .. d.message,
          type = M.severity(d.severity) == vim.diagnostic.severity.WARN and 'W' or 'E' })
      end
    end
  end
  table.sort(items, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    return a.lnum < b.lnum
  end)
  M.set_qf(items)
  return items
end

local runs = {} -- real app root → the latest run { handle }

-- run checks the app. A newer run for the same app (by real path) cancels the older one,
-- whose result is then dropped even if it arrives.
function M.run(app_root, o)
  o = o or {}
  local key = real(app_root)
  local prev = runs[key]
  if prev and prev.handle then pcall(function() prev.handle:kill('sigterm') end) end
  local mine = {}
  runs[key] = mine
  local args = { 'check', '--json', app_root }
  mine.handle = cli.run(args, { cwd = app_root }, function(res)
    if runs[key] ~= mine then return end
    runs[key] = nil
    if res.code == 2 or (res.code ~= 0 and #res.objects == 0) or (res.json and res.json.error) then
      cli.report(args, res)
      return
    end
    local items = M.publish(app_root, res.objects)
    if o.open_qf then
      for _, item in ipairs(items) do
        if item.type == 'E' then
          vim.cmd('copen')
          break
        end
      end
    end
    if o.on_done then o.on_done(res) end
  end)
  if not mine.handle and runs[key] == mine then runs[key] = nil end
end

-- apply_fix replaces the fix's byte range (1-based, exclusive end) with its text.
function M.apply_fix(buf, fix)
  local ok, err = pcall(vim.api.nvim_buf_set_text, buf, fix.line - 1, fix.col - 1, fix.endLine - 1, fix.endCol - 1,
    vim.split(fix.replace, '\n', { plain = true }))
  if not ok then return false, 'alder: the fix no longer matches the buffer; save to re-check (' .. tostring(err) .. ')' end
  return true
end

local function at_cursor(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local here, line = nil, nil
  for _, d in ipairs(vim.diagnostic.get(buf, { namespace = M.ns, lnum = row })) do
    line = line or d
    local ends = d.end_lnum > row or col < d.end_col or d.end_col == d.col
    if col >= d.col and ends then here = here or d end
  end
  return here, line
end

-- fix_at_cursor applies the fix of the diagnostic under the cursor (else the first one with a
-- fix on the cursor's line). It refuses when the buffer changed since the check published its
-- diagnostics: the fix's range would land on the wrong bytes.
function M.fix_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local here = at_cursor(buf)
  local pick = here and here.user_data and here.user_data.fix and here
  if not pick then
    for _, d in ipairs(vim.diagnostic.get(buf, { namespace = M.ns, lnum = row })) do
      if d.user_data and d.user_data.fix then pick = d break end
    end
  end
  if not pick then
    vim.notify('alder: no fix under the cursor', vim.log.levels.WARN)
    return false
  end
  if vim.b[buf].alder_check_tick ~= vim.api.nvim_buf_get_changedtick(buf) then
    vim.notify('alder: the fix no longer matches the buffer; save to re-check', vim.log.levels.ERROR)
    return false
  end
  local ok, err = M.apply_fix(buf, pick.user_data.fix)
  if not ok then vim.notify(err, vim.log.levels.ERROR) end
  return ok
end

-- under_cursor is the alder diagnostic under the cursor from any namespace (the server's or
-- the CLI's): the one whose range holds the cursor, else the first alder one on the line.
local function under_cursor(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local line
  for _, d in ipairs(vim.diagnostic.get(buf, { lnum = row })) do
    if d.source == 'alder' and d.code then
      line = line or d
      local ends = d.end_lnum > row or col < d.end_col or d.end_col == d.col
      if col >= d.col and ends then return d end
    end
  end
  return line
end

local function show(text)
  vim.lsp.util.open_floating_preview(vim.split(vim.trim(text), '\n', { plain = true }), 'markdown',
    { border = 'rounded', max_width = 80, focus_id = 'alder-explain' })
end

-- explain shows the explanation of the given code or of the alder diagnostic under the cursor,
-- through the language server when attached and `alder explain` otherwise.
function M.explain(code)
  local buf = vim.api.nvim_get_current_buf()
  if not code or code == '' then
    local d = under_cursor(buf)
    code = d and d.code and tostring(d.code)
  end
  if not code then
    vim.notify('alder: no diagnostic under the cursor', vim.log.levels.WARN)
    return
  end
  if vim.b[buf].alder_lsp then
    require('alder.lsp').request(buf, 'workspace/executeCommand', { command = 'alder.explain', arguments = { code } },
      function(text) if text then show(text) end end)
    return
  end
  cli.run({ 'explain', code }, { cwd = vim.fn.getcwd() }, function(res)
    if res.code ~= 0 then
      cli.report({ 'explain', code }, res, { bug_on_2 = false })
      return
    end
    show(res.stdout)
  end)
end

-- for_current runs a check for the current buffer's app, or says there is none.
function M.for_current(o)
  local r = root.require_for_buf(0)
  if r then M.run(r, o) end
end

return M
