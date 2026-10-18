local cli = require('alder.cli')
local root = require('alder.root')

local M = {}

function M.address(h)
  return h.module .. '.' .. h.decl .. (h.arm and h.arm ~= '' and ('.' .. h.arm) or '')
end

-- hole_at returns the hole of rel_file whose `?name` contains line/col (1-based, bytes), or the
-- file's only hole when there is just one. `alder fill --list` reports col at the `?`.
function M.hole_at(holes, rel_file, line, col)
  local in_file = {}
  for _, h in ipairs(holes) do
    if h.file == rel_file then table.insert(in_file, h) end
  end
  for _, h in ipairs(in_file) do
    if h.line == line and col >= h.col and col < h.col + 1 + #h.name then return h end
  end
  if #in_file == 1 then return in_file[1] end
  return nil
end

local function relative(app_root, path)
  local r, p = vim.uv.fs_realpath(app_root) or app_root, vim.uv.fs_realpath(path) or path
  if p:sub(1, #r + 1) == r .. '/' then return p:sub(#r + 2) end
  return nil
end

local scratches = {} -- buf → { app_root, hole, bang }

local function close(buf)
  scratches[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end

-- submit pipes the expression below the header to `alder fill` through the generator path
-- (which applies, reloads buffers and re-checks the app). A refusal is notified and listed in
-- an `alder fill` quickfix list by generate.run: it describes the dry-run copy, so nothing is
-- published as diagnostics, and the expression stays in the scratch for editing. Success
-- closes the scratch.
function M.submit(buf)
  local s = scratches[buf]
  if not s then return end
  local body = table.concat(vim.api.nvim_buf_get_lines(buf, 2, -1, false), '\n')
  local fargs = s.bang and { 'fill', '--decl', s.hole.module .. '.' .. s.hole.decl, '-' }
    or { 'fill', M.address(s.hole), '-', '--hole', '?' .. s.hole.name }
  require('alder.generate').run(fargs, {
    preview = false,
    app_root = s.app_root,
    stdin = body,
    on_done = function(res)
      if res.code == 0 and res.json and not res.json.error then close(buf) end
    end,
  })
end

local function open_scratch(app_root, hole, bang)
  -- a hole has its own scratch; the whole-declaration (bang) one is named by the address alone
  local name = 'alder://fill/' .. M.address(hole) .. (bang and '' or ('/?' .. hole.name))
  -- reopening a hole whose scratch is still open goes back to it, keeping the typed text
  local old = cli.buf_named(name)
  if old and scratches[old] then
    local win = vim.fn.bufwinid(old)
    if win ~= -1 then vim.api.nvim_set_current_win(win) else vim.cmd('botright sbuffer ' .. old) end
    return
  end
  if old then pcall(vim.api.nvim_buf_delete, old, { force = true }) end
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    { ('-- ?%s : %s'):format(hole.name, hole.type), '-- ' .. M.address(hole), '' })
  vim.bo[buf].filetype = 'alder'
  vim.bo[buf].modified = false
  scratches[buf] = { app_root = app_root, hole = hole, bang = bang }
  vim.keymap.set('n', '<CR>', function() M.submit(buf) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', 'q', function() close(buf) end, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    vim.bo[buf].modified = false
    M.submit(buf)
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() scratches[buf] = nil end })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
end

-- fill is :AlderFill[!]: the hole under the cursor (or the file's only hole) in a scratch
-- split; with bang, the hole's whole declaration body (--decl).
function M.fill(bang)
  local file = vim.api.nvim_buf_get_name(0)
  local app_root = root.for_buf(0)
  if not app_root then
    vim.notify('alder: no `app/` directory above this file', vim.log.levels.ERROR)
    return
  end
  if #require('alder.generate').modified(app_root) > 0 then
    vim.notify('alder: save all buffers first (:wall)', vim.log.levels.ERROR)
    return
  end
  local rel = relative(app_root, file)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local args = { 'fill', '--list', '--json', '--dir', app_root }
  cli.run(args, { cwd = app_root }, function(res)
    if not res.json or res.code ~= 0 then
      cli.report(args, res)
      return
    end
    local hole = rel and M.hole_at(res.json.holes or {}, rel, row, col + 1)
    if not hole then
      vim.notify('alder: no hole under the cursor', vim.log.levels.WARN)
      return
    end
    open_scratch(app_root, hole, bang)
  end)
end

return M
