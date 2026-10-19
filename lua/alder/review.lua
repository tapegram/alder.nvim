-- review: the second modal (<C-o>): what the plan leaves to you on top (holes, imports,
-- migration, diagnostics), the files on the left, the unified diff of the one under the cursor
-- on the right. <CR> applies, q / <Esc> go back. It floats (zindex 60) over the generator modal.
-- Lifted from durandal.nvim's preview.lua.
local ui = require('alder.ui')
local M = {}

local function present(v) return v ~= nil and v ~= '' end

-- model is the plan as the review shows it. Pure; absent fields are fine.
function M.model(plan)
  plan = plan or {}
  local notes, files = {}, {}
  local can_apply = not present(plan.error)
  if not can_apply then notes[#notes + 1] = '✗ ' .. plan.error end
  for _, d in ipairs(plan.diagnostics or {}) do
    notes[#notes + 1] = ('%s:%d:%d %s %s'):format(d.file or '', d.line or 0, d.col or 0, d.code or '', d.message or '')
  end
  for _, h in ipairs(plan.holes or {}) do
    local addr = (h.module or '') .. '.' .. (h.decl or '') .. (present(h.arm) and ('.' .. h.arm) or '')
    notes[#notes + 1] = ('? %s : %s  (%s)'):format(h.name or '', h.type or '', addr)
  end
  for _, i in ipairs(plan.imports or {}) do notes[#notes + 1] = 'import ' .. i end
  for _, m in ipairs(plan.migration or {}) do notes[#notes + 1] = 'migration: ' .. m end
  for _, f in ipairs(plan.files or {}) do
    files[#files + 1] = {
      path = f.path or '',
      new = f.before == nil,
      removed = f.after == nil,
      diff = vim.diff(f.before or '', f.after or '', { result_type = 'unified', ctxlen = 3 }),
    }
  end
  return { notes = notes, files = files, can_apply = can_apply }
end

local function title(id, m)
  return (id or 'plan') .. (m.can_apply and '  <CR> apply · Esc back' or '  ✗ cannot apply · q back')
end

local function fill(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '' })
  vim.bo[buf].modifiable = false
end

-- open draws the review over whatever is open. plan is the raw `alder/plan` answer. opts: id,
-- on_apply(), on_back(). Returns false (and says so) when there is nothing to show.
function M.open(plan, opts)
  opts = opts or {}
  local m = M.model(ui.plain(plan))
  if #m.files == 0 and m.can_apply then
    vim.notify('alder: nothing to change', vim.log.levels.INFO)
    if opts.on_back then opts.on_back() end
    return false
  end
  local Layout = require('nui.layout')
  local notes = ui.pane(title(opts.id, m), { focusable = false, zindex = 60 })
  local files = ui.pane('files', { enter = true, zindex = 60, win_options = { cursorline = true } })
  local diff = ui.pane('diff', { zindex = 60, buf_options = { filetype = 'diff' } })
  local note_lines = #m.notes > 0 and m.notes or { 'no holes, no warnings' }
  local layout = Layout(
    { relative = 'editor', position = '50%', size = { width = '90%', height = '80%' } },
    Layout.Box({
      Layout.Box(notes, { size = math.min(#note_lines, 6) + 2 }),
      Layout.Box({ Layout.Box(files, { size = '30%' }), Layout.Box(diff, { size = '70%' }) }, { dir = 'row', grow = 1 }),
    }, { dir = 'col' })
  )
  layout:mount()
  fill(notes.bufnr, note_lines)
  fill(files.bufnr, vim.tbl_map(function(f) return (f.new and '+ ' or f.removed and '- ' or '~ ') .. f.path end, m.files))
  local function show(i)
    local f = m.files[i]
    if f then fill(diff.bufnr, vim.split(f.diff, '\n', { plain = true })) end
  end
  show(1)
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = files.bufnr, callback = function() show(vim.api.nvim_win_get_cursor(files.winid)[1]) end })
  local closed = false
  local function close()
    if closed then return end
    closed = true
    pcall(function() layout:unmount() end)
  end
  local function back()
    close()
    if opts.on_back then opts.on_back() end
  end
  -- leaving both panes for another window closes the review (it is never left floating)
  for _, p in ipairs({ files, diff }) do
    vim.api.nvim_create_autocmd('WinLeave', {
      buffer = p.bufnr,
      callback = function()
        vim.schedule(function()
          if closed then return end
          local w = vim.api.nvim_get_current_win()
          if w ~= files.winid and w ~= diff.winid then back() end
        end)
      end,
    })
  end
  local function accept()
    if not m.can_apply then return end
    close()
    if opts.on_apply then opts.on_apply() end
  end
  for _, p in ipairs({ files, diff }) do
    p:map('n', 'q', back, { noremap = true, nowait = true })
    p:map('n', '<Esc>', back, { noremap = true, nowait = true })
    p:map('n', '<CR>', accept, { noremap = true, nowait = true })
  end
  files:map('n', '<Tab>', function() vim.api.nvim_set_current_win(diff.winid) end, { noremap = true, nowait = true })
  diff:map('n', '<Tab>', function() vim.api.nvim_set_current_win(files.winid) end, { noremap = true, nowait = true })
  return true
end

return M
