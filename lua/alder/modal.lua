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
  end
end

-- render_form and the preview functions are defined in the second half (Task 7); until then:
local render_form = function() end
M.send_preview = function() end

-- select makes filtered[i] the current generator: its here values (and preset, from a code
-- action) become the sets, the form and preview start over and a preview is asked for at once.
function M.select(i, preset)
  local s = M.state
  if not s then return end
  s.selected = math.max(1, math.min(i, #s.filtered))
  local sel = M.selected()
  s.preset = vim.tbl_extend('force', {}, (sel and sel.sets) or {}, preset or {})
  s.typed, s.fields, s.focus, s.pick, s.ready, s.preview = {}, {}, nil, 1, false, nil
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
  end, function() M.opening = nil end)
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

-- Task 7 fills these in; stubs keep Task 6's tests meaningful.
function M.form_keys() end
function M.focus_field() end
function M.enter() end
function M.review() end

return M
