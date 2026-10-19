-- modal: the generator UI — one centred nui layout: a search line over the generator list on
-- the left, the selected generator's form above its live preview on the right. Every edit asks
-- the server for alder/preview; <CR> plans and applies through apply.lua; <C-o> opens the
-- review. Modelled on durandal.nvim's generate.lua: a state singleton, a sequence number on
-- previews, an idempotent close.
local ui = require('alder.ui')
local picker = require('alder.picker')
local form = require('alder.form')
local preview = require('alder.preview')

local M = {}
M.state = nil
local ns = vim.api.nvim_create_namespace('alder.modal')
local DEBOUNCE_MS = 80

local function request(...) return require('alder.lsp').request(...) end

-- params are a generator request's: the origin document and cursor, plus extra.
local function params(s, extra)
  local p = {
    textDocument = { uri = vim.uri_from_bufnr(s.buf) },
    position = { line = s.origin.cursor[1] - 1, character = s.origin.cursor[2] },
  }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end

-- sets_payload is the sets to send: an object even when empty.
local function sets_payload(s)
  local out = vim.empty_dict()
  for k, v in pairs(form.sets(s.preset, s.typed)) do out[k] = v end
  return out
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '' })
  vim.bo[buf].modifiable = false
end

-- selected is the generator item under the list cursor, nil for an empty list.
function M.selected()
  local s = M.state
  return s and s.filtered[s.selected] or nil
end

local function render_list()
  local s = M.state
  local lines, marks, headings = picker.lines(s.filtered, s.query == '')
  set_lines(s.bufs.list, lines)
  vim.api.nvim_buf_clear_namespace(s.bufs.list, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(s.bufs.list, ns, m.row - 1, m.col, { end_col = #lines[m.row], hl_group = m.hl })
  end
  for _, h in ipairs(headings) do
    vim.api.nvim_buf_set_extmark(s.bufs.list, ns, h.row - 1, 0, { virt_lines = { { { h.text, 'Comment' } } }, virt_lines_above = true })
  end
  s.popups.list.border:set_text('bottom', (' %d of %d '):format(#s.filtered, #s.items), 'right')
  if #s.filtered > 0 and vim.api.nvim_win_is_valid(s.win.list) then
    pcall(vim.api.nvim_win_set_cursor, s.win.list, { s.selected, 0 })
    -- a heading above row 1 is only drawn when topfill says so (setting the cursor resets it)
    if headings[1] and headings[1].row == 1 then
      vim.api.nvim_win_call(s.win.list, function()
        local v = vim.fn.winsaveview()
        if v.topline == 1 then vim.fn.winrestview({ topline = 1, topfill = 1 }) end
      end)
    end
  end
end

local render_form -- defined with the form, below

-- updating shows (or hides) the preview pane's "updating…" state.
local function updating(on)
  local s = M.state
  if not s or not s.popups then return end
  s.updating = on
  s.popups.preview.border:set_text('bottom', on and ' updating… ' or '', 'right')
  if s.win and vim.api.nvim_win_is_valid(s.win.preview) then
    vim.wo[s.win.preview].winhighlight = on and 'Normal:Comment,FloatBorder:FloatBorder' or 'Normal:Normal,FloatBorder:FloatBorder'
  end
end

-- invalidate drops every preview in flight or waiting: its answer no longer counts and the form
-- is not ready until a newer one arrives.
local seq_counter = 0 -- shared by every modal, so a closed modal's answer never matches a new one's
local function invalidate(s)
  seq_counter = seq_counter + 1
  s.seq = seq_counter
  s.ready = false
  s.timer:stop()
end

-- select makes filtered[i] the current generator: its here values (and preset, from a code
-- action) become the sets, the form and preview start over and a preview is asked for at once.
function M.select(i, preset)
  local s = M.state
  if not s then return end
  s.selected = math.max(1, math.min(i, #s.filtered))
  local sel = M.selected()
  s.preset = vim.tbl_extend('force', {}, (sel and sel.sets) or {}, preset or {})
  s.typed, s.fields, s.focus, s.pick, s.moved, s.preview = {}, {}, nil, 1, false, nil
  invalidate(s)
  updating(false)
  render_list()
  render_form()
  set_lines(s.bufs.preview, {})
  s.popups.preview.border:set_text('top', ' Preview ', 'left')
  if sel then M.send_preview() end
end

-- type_query filters the list and selects the first (best) row.
function M.type_query(q)
  local s = M.state
  if not s then return end
  s.query = q
  s.filtered = picker.filter(s.items, q)
  M.select(1)
end

-- on_search_changed reads the search line and filters by it; the search buffer's TextChanged
-- autocmds call it.
function M.on_search_changed()
  local s = M.state
  if not s or not vim.api.nvim_buf_is_valid(s.bufs.search) then return end
  local line = vim.api.nvim_buf_get_lines(s.bufs.search, 0, 1, false)[1] or ''
  if line ~= s.query then M.type_query(line) end
end

-- move steps the selection.
function M.move(delta)
  local s = M.state
  if not s or #s.filtered == 0 then return end
  M.select(s.selected + delta)
end

local function mount()
  local s = M.state
  local Layout = require('nui.layout')
  s.popups = {
    search = ui.pane('Generate', { enter = true }),
    list = ui.pane(nil, { win_options = { cursorline = true } }),
    form = ui.pane('Form'),
    preview = ui.pane('Preview', { buf_options = { filetype = 'diff' } }),
  }
  local box
  if ui.narrow() then
    local room = math.floor(vim.o.lines * 0.8) - 3
    box = Layout.Box({
      Layout.Box(s.popups.search, { size = 3 }),
      Layout.Box(s.popups.list, { size = math.max(5, math.floor(room * 0.3)) }),
      Layout.Box(s.popups.form, { size = math.max(4, math.floor(room * 0.25)) }),
      Layout.Box(s.popups.preview, { grow = 1 }),
    }, { dir = 'col' })
  else
    box = Layout.Box({
      Layout.Box({ Layout.Box(s.popups.search, { size = 3 }), Layout.Box(s.popups.list, { grow = 1 }) }, { dir = 'col', size = '35%' }),
      Layout.Box({ Layout.Box(s.popups.form, { size = 10 }), Layout.Box(s.popups.preview, { grow = 1 }) }, { dir = 'col', size = '65%' }),
    }, { dir = 'row' })
  end
  s.layout = Layout(vim.deepcopy(ui.modal), box)
  s.layout:mount()
  s.bufs, s.win = {}, {}
  for name, p in pairs(s.popups) do
    s.bufs[name], s.win[name] = p.bufnr, p.winid
  end
  for _, name in ipairs({ 'list', 'preview' }) do vim.bo[s.bufs[name]].modifiable = false end

  -- the search line: typing filters; the arrows move; Tab goes to the form; Esc closes
  local search = s.bufs.search
  local function map(lhs, fn) vim.keymap.set({ 'i', 'n' }, lhs, fn, { buffer = search, nowait = true }) end
  map('<Down>', function() M.move(1) end)
  map('<C-n>', function() M.move(1) end)
  map('<Up>', function() M.move(-1) end)
  map('<C-p>', function() M.move(-1) end)
  map('<Tab>', function() M.focus_field(1) end)
  map('<S-Tab>', function() M.focus_prev() end)
  map('<CR>', function() M.enter() end)
  map('<C-o>', function() M.review() end)
  map('<Esc>', function() M.close() end)
  map('<C-c>', function() M.close() end)
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, { buffer = search, callback = M.on_search_changed })
  -- leaving the modal for another window closes it (unless the review is up)
  for _, p in pairs(s.popups) do
    p:on('BufLeave', function()
      vim.schedule(function()
        local st = M.state
        if not st or st.suspended then return end
        local cur = vim.api.nvim_get_current_win()
        for _, w in pairs(st.win) do
          if w == cur then return end
        end
        M.close()
      end)
    end)
  end
  M.form_keys()
  -- no completion popups over the search and form lines: they would take <CR>, <Tab> and <Down>
  for _, name in ipairs({ 'search', 'form' }) do
    local b = s.bufs[name]
    vim.b[b].completion = false -- blink.cmp
    vim.api.nvim_buf_call(b, function()
      pcall(function() require('cmp').setup.buffer({ enabled = false }) end) -- nvim-cmp
    end)
  end
  vim.api.nvim_set_current_win(s.win.search)
  vim.cmd.startinsert()
end

-- open asks for the generators at buf's cursor and shows the modal; opts.generator (an id) and
-- opts.sets preset it, as a code action does.
function M.open(buf, opts)
  opts = opts or {}
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not ui.has_nui() then return vim.notify(ui.MISSING, vim.log.levels.WARN) end
  M.close()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then win = vim.fn.bufwinid(buf) end
  local origin = { win = win, cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 } }
  local token = {}
  M.opening = token
  request(buf, 'alder/generators', { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = origin.cursor[1] - 1, character = origin.cursor[2] } }, function(result)
    if M.opening ~= token then return end
    M.opening = nil
    local items = (ui.plain(result) or {}).generators or {}
    if #items == 0 then return vim.notify('alder: no generators', vim.log.levels.WARN) end
    M.state = {
      buf = buf, origin = origin, items = items, filtered = picker.filter(items, ''), selected = 1, query = '',
      preset = {}, typed = {}, fields = {}, seq = 0, ready = false, timer = vim.uv.new_timer(),
    }
    mount()
    local idx = 1
    if opts.generator then
      for i, it in ipairs(items) do
        if it.id == opts.generator then idx = i end
      end
      M.state.focus_first_missing = true
    end
    M.select(idx, opts.sets)
  end, function()
    if M.opening == token then M.opening = nil end
  end)
end

-- close is idempotent: stop the timer, leave insert, unmount, restore the origin window and
-- cursor (again scheduled: leaving insert moves the cursor a column).
function M.close()
  M.opening = nil
  local s = M.state
  if not s then return end
  M.state = nil
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  vim.cmd.stopinsert()
  pcall(function() s.layout:unmount() end)
  local function restore()
    if vim.api.nvim_win_is_valid(s.origin.win) then
      vim.api.nvim_set_current_win(s.origin.win)
      pcall(vim.api.nvim_win_set_cursor, s.origin.win, s.origin.cursor)
    end
  end
  restore()
  vim.schedule(restore)
end

-- ── The form ─────────────────────────────────────────────────────────────────
-- One line per field: the line's text is the value, edited in place; the label is inline
-- virtual text, the note at the end of the line; a focused choice field lists its options
-- under it; a switch is `[x] name`, toggled with <Space>.

-- start_pick is the index of the field's current value among its options (1 when absent).
local function start_pick(s, f)
  local cur = s.typed[f.name]
  if cur == nil then cur = f.value end
  for i, o in ipairs(form.options(f, s.typed[f.name])) do
    if o == cur then return i end
  end
  return 1
end

render_form = function()
  local s = M.state
  if not s or not s.bufs then return end
  local buf = s.bufs.form
  local lines, marks = form.lines(s.fields, s.typed)
  if #lines == 0 then lines = { '' } end
  vim.bo[buf].modifiable = true
  -- only the lines that differ (a re-render is not an edit of yours), then remember the tick:
  -- a change with that tick is this render, not typing
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #current ~= #lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    for i, l in ipairs(lines) do
      if current[i] ~= l then vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { l }) end
    end
  end
  s.tick = vim.api.nvim_buf_get_changedtick(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    if m.label ~= '' then
      vim.api.nvim_buf_set_extmark(buf, ns, m.row - 1, 0, { virt_text = { { m.label, 'Identifier' } }, virt_text_pos = 'inline', right_gravity = false })
    end
    if m.note then
      vim.api.nvim_buf_set_extmark(buf, ns, m.row - 1, 0, { virt_text = { { '  ' .. m.note, m.note_hl } }, virt_text_pos = 'eol' })
    end
  end
  local f = s.focus and s.fields[s.focus]
  if f and f.choices and #f.choices > 0 then
    local opts = form.options(f, s.typed[f.name])
    local pick = math.max(1, math.min(s.pick or 1, #opts))
    local from = math.max(1, math.min(pick - 5, #opts - 5))
    local shown = {}
    for k = from, math.min(#opts, from + 5) do
      shown[#shown + 1] = { { (k == pick and '▸ ' or '  ') .. opts[k], k == pick and 'PmenuSel' or 'Pmenu' } }
    end
    if #shown > 0 then vim.api.nvim_buf_set_extmark(buf, ns, s.focus - 1, 0, { virt_lines = shown }) end
  end
  local sel = M.selected()
  s.popups.form.border:set_text('top', sel and (' ' .. sel.id .. '  ' .. (sel.summary or '') .. ' ') or ' Form ', 'left')
end

-- set_field records text for field name and asks for a preview (debounced). Typing into a
-- choice field filters its options, so the pick restarts and counts as chosen.
function M.set_field(name, text)
  local s = M.state
  if not s then return end
  s.typed[name] = text
  s.pick, s.moved = 1, true
  render_form()
  M.request_preview()
end

-- focus_field puts the cursor on row (wrapping) in insert mode (normal for a switch).
function M.focus_field(row)
  local s = M.state
  if not s or #s.fields == 0 then return end
  row = ((row - 1) % #s.fields) + 1
  s.focus, s.moved = row, false
  s.pick = start_pick(s, s.fields[row])
  vim.api.nvim_set_current_win(s.win.form)
  local line = vim.api.nvim_buf_get_lines(s.bufs.form, row - 1, row, false)[1] or ''
  pcall(vim.api.nvim_win_set_cursor, s.win.form, { row, #line })
  render_form()
  if s.fields[row].kind == 'bool' then vim.cmd.stopinsert() else vim.cmd.startinsert({ bang = true }) end
end

function M.focus_search()
  local s = M.state
  if not s then return end
  s.focus = nil
  render_form()
  vim.api.nvim_set_current_win(s.win.search)
  vim.cmd.startinsert({ bang = true })
end

function M.focus_next()
  local s = M.state
  if not s then return end
  M.commit_option()
  if s.focus == nil then return M.focus_field(1) end
  if s.focus >= #s.fields then return M.focus_search() end
  M.focus_field(s.focus + 1)
end

function M.focus_prev()
  local s = M.state
  if not s then return end
  M.commit_option()
  if s.focus == nil then return M.focus_field(#s.fields) end
  if s.focus <= 1 then return M.focus_search() end
  M.focus_field(s.focus - 1)
end

-- option moves through the focused choice field's options; false when there are none.
function M.option(delta)
  local s = M.state
  local f = s and s.focus and s.fields[s.focus]
  if not f or not f.choices or #f.choices == 0 then return false end
  local n = #form.options(f, s.typed[f.name])
  if n == 0 then return false end
  s.pick = ((((s.pick or 1) + delta) - 1) % n) + 1
  s.moved = true
  render_form()
  return true
end

-- commit_option writes the picked option into the focused choice field. It does nothing until
-- the user moved the pick or typed a filter, so passing over a field never rewrites its value.
function M.commit_option()
  local s = M.state
  local f = s and s.focus and s.fields[s.focus]
  if not f or not s.moved or not f.choices or #f.choices == 0 then return end
  local opts = form.options(f, s.typed[f.name])
  local pick = opts[math.max(1, math.min(s.pick or 1, #opts))]
  local cur = s.typed[f.name]
  if cur == nil then cur = f.value end
  if pick and pick ~= cur then M.set_field(f.name, pick) end
  s.moved = false
end

-- toggle flips the switch under the cursor. It is the only writer of a switch's typed value.
function M.toggle()
  local s = M.state
  if not s then return end
  local row = vim.api.nvim_win_get_cursor(s.win.form)[1]
  local f = s.fields[row]
  if not f or f.kind ~= 'bool' then return end
  local line = vim.api.nvim_buf_get_lines(s.bufs.form, row - 1, row, false)[1] or ''
  s.focus = row
  M.set_field(f.name, form.is_on(line) and 'false' or 'true')
end

-- on_form_changed: typing in the focused field, or something that broke the rows (a joined or
-- added line) — put back, never losing a value. A change with the last render's tick is the
-- render itself.
function M.on_form_changed()
  local s = M.state
  if not s or not s.bufs then return end
  local buf = s.bufs.form
  if vim.api.nvim_buf_get_changedtick(buf) == s.tick then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines ~= math.max(1, #s.fields) then return render_form() end
  local row = vim.api.nvim_win_get_cursor(s.win.form)[1]
  local f = s.fields[row]
  if not f then return end
  if f.kind == 'bool' then return render_form() end
  s.focus = row
  local shown = s.typed[f.name] ~= nil and s.typed[f.name] or (f.value or '')
  if lines[row] ~= shown then
    s.typed[f.name] = lines[row]
    s.pick, s.moved = 1, true
    render_form()
    M.request_preview()
  else
    s.tick = vim.api.nvim_buf_get_changedtick(buf)
  end
end

-- on_cursor_moved: the cursor on another field's line focuses it.
function M.on_cursor_moved()
  local s = M.state
  if not s or not s.bufs or vim.api.nvim_get_current_win() ~= s.win.form then return end
  local row = vim.api.nvim_win_get_cursor(s.win.form)[1]
  if s.fields[row] and row ~= s.focus then
    M.commit_option()
    s.focus, s.moved = row, false
    s.pick = start_pick(s, s.fields[row])
    render_form()
    -- a switch row is toggled with <Space> in normal mode
    if s.fields[row].kind == 'bool' then vim.cmd.stopinsert() end
  end
end

-- form_keys maps the form pane.
function M.form_keys()
  local s = M.state
  local buf = s.bufs.form
  local function map(lhs, fn) vim.keymap.set({ 'i', 'n' }, lhs, fn, { buffer = buf, nowait = true }) end
  map('<Tab>', M.focus_next)
  map('<S-Tab>', M.focus_prev)
  map('<CR>', function() M.enter() end)
  map('<C-o>', function() M.review() end)
  map('<Esc>', function() M.close() end)
  map('<C-c>', function() M.close() end)
  for lhs, delta in pairs({ ['<Down>'] = 1, ['<C-n>'] = 1, ['<Up>'] = -1, ['<C-p>'] = -1 }) do
    map(lhs, function()
      if not M.option(delta) then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(delta > 0 and '<Down>' or '<Up>', true, false, true), 'n', false)
      end
    end)
  end
  vim.keymap.set('n', '<Space>', M.toggle, { buffer = buf, nowait = true })
  for _, k in ipairs({ 'o', 'O', 'dd', 'J', 'p', 'P' }) do vim.keymap.set('n', k, '<Nop>', { buffer = buf, nowait = true }) end
  -- <BS> at the start of a line would join it with the one above: swallow it there
  vim.keymap.set('i', '<BS>', function()
    return vim.api.nvim_win_get_cursor(0)[2] == 0 and '' or '<BS>'
  end, { buffer = buf, expr = true, nowait = true })
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, { buffer = buf, callback = function() M.on_form_changed() end })
  vim.api.nvim_create_autocmd({ 'CursorMovedI', 'CursorMoved' }, { buffer = buf, callback = function() M.on_cursor_moved() end })
end

-- ── The preview ──────────────────────────────────────────────────────────────

-- request_preview asks after a pause (one request for a burst of typing). The sets just
-- changed, so every earlier answer is stale from here on.
function M.request_preview()
  local s = M.state
  if not s then return end
  invalidate(s)
  updating(true)
  s.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function() M.send_preview() end))
end

-- failed handles a request error: the message is already shown; with no server attached there
-- is nothing to retry, so the modal closes rather than sit there stuck.
local function failed(s)
  if M.state ~= s then return false end
  if not require('alder.lsp').client(s.buf) then
    M.close()
    return true
  end
  return false
end

-- send_preview asks now; its answer counts only if it is still the latest.
function M.send_preview()
  local s = M.state
  local sel = M.selected()
  if not s or not sel then return end
  invalidate(s)
  local n = s.seq
  updating(true)
  request(s.buf, 'alder/preview', params(s, { id = sel.id, sets = sets_payload(s) }), function(result)
    vim.schedule(function()
      if M.state == s then M.on_preview(n, ui.plain(result) or {}) end
    end)
  end, function(err)
    vim.schedule(function()
      if M.state ~= s or failed(s) then return end
      M.on_preview(n, { error = 'the preview failed: ' .. tostring(err and err.message or err), files = {} })
    end)
  end)
end

function M.on_preview(n, r)
  local s = M.state
  if not s or n ~= s.seq then return end
  updating(false)
  s.preview = r
  s.fields = r.fields or s.fields
  s.ready = r.ready == true
  render_form()
  local lines, hls = preview.render(r)
  set_lines(s.bufs.preview, lines)
  vim.api.nvim_buf_clear_namespace(s.bufs.preview, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(s.bufs.preview, ns, h.row - 1, 0, { line_hl_group = h.hl })
  end
  local main = r.files and r.files[1]
  s.popups.preview.border:set_text('top', main and (' ' .. main.path .. ' ') or ' Preview ', 'left')
  if vim.api.nvim_win_is_valid(s.win.preview) then
    vim.api.nvim_win_call(s.win.preview, function() vim.fn.winrestview({ topline = preview.first_hunk(lines) }) end)
  end
  if s.focus_first_missing then
    s.focus_first_missing = nil
    local row = form.first_invalid(s.fields)
    if row then M.focus_field(row) end
  end
end

-- ── Enter and review ─────────────────────────────────────────────────────────

-- apply closes the modal and applies id with the current sets through apply.lua.
local function apply(s, id, planned)
  local buf, sets, pos = s.buf, planned or sets_payload(s), s.origin.cursor
  M.close()
  require('alder.apply').run(buf, id, sets, nil, pos)
end

-- enter applies when the form is ready, else goes to the first invalid field. While a preview
-- is in flight it does nothing: the sets on screen are not the ones that were previewed.
function M.enter()
  local s = M.state
  local sel = M.selected()
  if not s or not sel then return end
  M.on_form_changed() -- a keystroke still unread counts
  M.commit_option()
  if s.updating then return end
  if not s.ready then
    local row = form.first_invalid(s.fields)
    if row then M.focus_field(row) end
    return
  end
  apply(s, sel.id)
end

-- review plans and opens the review modal over this one; q comes back here.
function M.review()
  local s = M.state
  local sel = M.selected()
  if not s or not sel then return end
  M.on_form_changed() -- a keystroke still unread counts
  M.commit_option()
  local planned = sets_payload(s)
  request(s.buf, 'alder/plan', params(s, { id = sel.id, sets = planned }), function(plan)
    local st = M.state
    if st ~= s then return end
    -- the form changed while the plan was in flight: it is not the plan of what is on screen
    local now = M.selected()
    if not now or now.id ~= sel.id or not vim.deep_equal(planned, sets_payload(st)) then return end
    st.suspended = true
    vim.cmd.stopinsert()
    local shown = require('alder.review').open(ui.plain(plan) or {}, {
      id = sel.id,
      on_apply = function() apply(st, sel.id, planned) end,
      on_back = function()
        if M.state ~= st then return end
        st.suspended = false
        if st.focus then M.focus_field(st.focus) else M.focus_search() end
      end,
    })
    if not shown then st.suspended = false end
  end, function()
    vim.schedule(function() failed(s) end)
  end)
end

return M
