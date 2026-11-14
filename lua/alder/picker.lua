-- picker: the fuzzy filter and list lines of the generator modal (pure: modal.lua renders), and
-- the floating picker the routes and search pickers share (open): a query line, a list, an
-- optional detail pane for the selected item, over a fixed list filtered locally or an async
-- source asked per query.
local M = {}

-- filter is the items whose `id summary` fuzzy-match query, best first; a copy of all of them,
-- in the server's order (here first), for an empty query.
-- text(item), when given, is the string to match instead (the routes picker matches paths).
function M.filter(items, query, text)
  if query == nil or query == '' then return vim.list_slice(items) end
  text = text or function(it) return it.id .. ' ' .. (it.summary or '') end
  local keyed = {}
  for _, it in ipairs(items) do keyed[#keyed + 1] = { text = text(it), item = it } end
  local out = {}
  for _, k in ipairs(vim.fn.matchfuzzy(keyed, query, { key = 'text' })) do out[#out + 1] = k.item end
  return out
end

-- lines renders items: `id`, two spaces past the longest id, the summary. marks are the
-- summaries' {row, col, hl}; headings (when grouped) go above the first here item and the
-- first other one as virtual lines.
function M.lines(items, grouped)
  local lines, marks, headings = {}, {}, {}
  local width = 0
  for _, it in ipairs(items) do width = math.max(width, #it.id) end
  local seen_here, seen_rest = false, false
  for i, it in ipairs(items) do
    local pad = string.rep(' ', width - #it.id + 2)
    lines[i] = it.id .. pad .. (it.summary or '')
    marks[i] = { row = i, col = #it.id + #pad, hl = 'Comment' }
    if grouped then
      if it.here and not seen_here then
        headings[#headings + 1] = { row = i, text = '── here ──' }
        seen_here = true
      elseif not it.here and not seen_rest then
        headings[#headings + 1] = { row = i, text = '── all ──' }
        seen_rest = true
      end
    end
  end
  return lines, marks, headings
end

-- ── The window ───────────────────────────────────────────────────────────────
-- open(opts) -> picker. opts:
--   title      the query window's title
--   query      the starting text (the cursor goes at its end)
--   hint       a dim line in the list area while the query is empty and there are no items
--   source     { items = list, filter = fn(items, q) } (local), or { fetch = fn(q, done) }
--              (async: done(items, note); the picker debounces and drops a stale done)
--   row(item)  -> label, signature: the list's two columns, cut with … to the window
--   detail(item) -> lines, marks, or nil for no detail pane; a mark is
--              { row (1-based), col (0-based byte), end_col (nil: the line's end), hl }
--   on_pick(item), on_close(), keys = { [lhs] = fn(item, picker) }
-- The picker's methods (called with `:`): set_query(q), move(delta), confirm(), close(),
-- selected(), set_items(items, note), set_busy(bool).
--
-- The windows are joined into one box: the query, a rule (which carries the note when there are
-- items), the list, and the detail pane; the footer `N of M` is on the bottom border.

local DEBOUNCE_MS = 80
local ns = vim.api.nvim_create_namespace('alder.picker')
local seq_counter = 0 -- shared by every picker, so a closed picker's answer never matches a new one's

local Picker = {}
Picker.__index = Picker

local function width_of(s) return vim.fn.strdisplaywidth(s) end

-- cut is s cut to w display cells, its last one `…` when anything was dropped.
local function cut(s, w)
  if width_of(s) <= w then return s end
  if w <= 0 then return '' end
  local n = vim.fn.strchars(s)
  while n > 0 and width_of(vim.fn.strcharpart(s, 0, n)) > w - 1 do n = n - 1 end
  return vim.fn.strcharpart(s, 0, n) .. '…'
end

-- row_lines renders the items in two columns: the label padded to the longest one (at most half
-- the width), two spaces, the signature; each line cut to width. marks are the signatures'
-- {row, col} (0-based) for the dim highlight.
local function row_lines(items, row, width)
  local cols = {}
  local lw = 0
  for i, it in ipairs(items) do
    local label, sig = row(it)
    cols[i] = { tostring(label or ''), sig }
    lw = math.max(lw, width_of(cols[i][1]))
  end
  lw = math.min(lw, math.max(8, math.floor((width - 2) / 2)))
  local lines, marks = {}, {}
  for i, c in ipairs(cols) do
    local label = cut(c[1], lw)
    if c[2] and c[2] ~= '' then
      local head = label .. string.rep(' ', lw - width_of(label) + 2)
      lines[i] = cut(head .. c[2], width)
      if #lines[i] > #head then marks[#marks + 1] = { i - 1, #head } end
    else
      lines[i] = cut(label, width)
    end
  end
  return lines, marks
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '' })
  vim.bo[buf].modifiable = false
end

local function valid(w) return w and vim.api.nvim_win_is_valid(w) end

function Picker:async() return self.source.fetch ~= nil end

function Picker:selected() return self.filtered[self.sel] end

-- render redraws the list, the note, the detail pane and the footer.
function Picker:render()
  if self.closed or not vim.api.nvim_buf_is_valid(self.list_buf) then return end
  local buf = self.list_buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local n = #self.filtered
  local note_on_rule = nil
  if n > 0 then
    self.sel = math.max(1, math.min(self.sel, n))
    local lines, marks = row_lines(self.filtered, self.row, self.width)
    set_lines(buf, lines)
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_row = m[1], end_col = #lines[m[1] + 1], hl_group = 'Comment' })
    end
    vim.api.nvim_buf_set_extmark(buf, ns, self.sel - 1, 0, { line_hl_group = 'PmenuSel' })
    pcall(vim.api.nvim_win_set_cursor, self.list_win, { self.sel, 0 })
    note_on_rule = self.note
  else
    self.sel = 1
    local dim = self.note or ((self.query == '' and self.hint) or nil)
    set_lines(buf, { dim and cut(dim, self.width) or '' })
    if dim then vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = 'Comment' }) end
  end
  pcall(vim.api.nvim_win_set_config, self.search_win, {
    footer = note_on_rule and (' ' .. cut(note_on_rule, self.width - 4) .. ' ') or '', footer_pos = 'left' })
  if self.detail_buf then
    local it = self:selected()
    local lines, marks = {}, {}
    if it then lines, marks = self.detail(it) end
    lines = lines or {}
    set_lines(self.detail_buf, lines)
    vim.api.nvim_buf_clear_namespace(self.detail_buf, ns, 0, -1)
    for _, m in ipairs(marks or {}) do
      local text = lines[m.row]
      if text then
        pcall(vim.api.nvim_buf_set_extmark, self.detail_buf, ns, m.row - 1, m.col or 0,
          { end_row = m.row - 1, end_col = m.end_col or #text, hl_group = m.hl })
      end
    end
  end
  -- local: how many match of all; async (the server already filtered): the selected one's place
  local footer = self:async() and (' %d of %d '):format(n > 0 and self.sel or 0, n)
    or (' %d of %d '):format(n, #self.items)
  pcall(vim.api.nvim_win_set_config, self.detail_win or self.list_win, { footer = footer, footer_pos = 'right' })
end

-- invalidate drops every fetch in flight or waiting: its answer no longer counts.
local function invalidate(self)
  seq_counter = seq_counter + 1
  self.seq = seq_counter
  if self.timer then self.timer:stop() end
end

-- fetch asks the async source now; its answer counts only if it is still the latest.
function Picker:fetch()
  if self.closed then return end
  invalidate(self)
  local n = self.seq
  self:set_busy(true)
  self.source.fetch(self.query, function(items, note)
    local function apply()
      if self.closed or n ~= self.seq then return end
      self:set_busy(false)
      self:set_items(items or {}, note)
    end
    if vim.in_fast_event() then vim.schedule(apply) else apply() end
  end)
end

function Picker:set_query(q)
  if self.closed then return end
  q = q or ''
  self.query = q
  if vim.api.nvim_buf_is_valid(self.search_buf)
    and (vim.api.nvim_buf_get_lines(self.search_buf, 0, 1, false)[1] or '') ~= q then
    vim.api.nvim_buf_set_lines(self.search_buf, 0, -1, false, { q })
  end
  if self:async() then
    -- one fetch for a burst of typing; every earlier answer is stale from here on
    invalidate(self)
    self:set_busy(true)
    self.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function() self:fetch() end))
    return
  end
  self.filtered = self.source.filter(self.items, q)
  self.sel = 1
  self:render()
end

-- set_items replaces the list (an async reply; for a local source, the items filtered by the
-- query). note is shown in the list when there are no items, else on the rule under the query.
function Picker:set_items(items, note)
  if self.closed then return end
  self.items, self.note = items or {}, note
  self.filtered = self:async() and self.items or self.source.filter(self.items, self.query)
  self.sel = 1
  self:render()
end

-- set_busy marks the title while a fetch is out.
function Picker:set_busy(on)
  if self.closed or self.busy == on then return end
  self.busy = on
  pcall(vim.api.nvim_win_set_config, self.search_win,
    { title = ' ' .. self.title .. (on and ' … ' or ' '), title_pos = 'left' })
end

function Picker:move(delta)
  local n = #self.filtered
  if self.closed or n == 0 then return end
  self.sel = ((self.sel - 1 + delta) % n) + 1
  self:render()
end

-- settle keeps the cursor where close (and on_pick) left it: leaving insert mode takes effect
-- only after the key's mapping returns and moves the cursor a column, so it is set again then —
-- only if that window is still current on the same buffer (another picker may have opened).
function Picker:settle()
  if not self.left_insert then return end
  local win = vim.api.nvim_get_current_win()
  local buf, cursor = vim.api.nvim_win_get_buf(win), vim.api.nvim_win_get_cursor(win)
  vim.schedule(function()
    if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, cursor)
    end
  end)
end

-- close is idempotent: stop the timer, close the windows, restore the origin window, cursor and
-- mode (insert is left only when the origin was not in insert mode).
function Picker:close()
  if self.closed then return end
  self.closed = true
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  if not self.origin.mode:find('^i') then
    vim.cmd.stopinsert()
    self.left_insert = true
  end
  for _, w in ipairs({ self.search_win, self.list_win, self.detail_win }) do
    if valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  local o = self.origin
  if valid(o.win) then
    pcall(vim.api.nvim_set_current_win, o.win)
    pcall(vim.api.nvim_win_set_cursor, o.win, o.cursor)
  end
  if not self.picking then self:settle() end
  if self.on_close then self.on_close() end
end

-- confirm closes the picker, then hands on_pick the selected item (if any).
function Picker:confirm()
  if self.closed then return end
  local it = self:selected()
  self.picking = true
  self:close()
  if it and self.on_pick then self.on_pick(it) end
  self:settle()
end

-- border: the box's pieces share their rules (├ ┤) so the windows read as one.
local function border(top, bottom_joins)
  local b = bottom_joins and { '┤', '─', '├' } or { '╯', '─', '╰' }
  if top then return { '╭', '─', '╮', '│', b[1], b[2], b[3], '│' } end
  return { '', '', '', '│', b[1], b[2], b[3], '│' }
end

function M.open(opts)
  local origin = { win = vim.api.nvim_get_current_win(), cursor = vim.api.nvim_win_get_cursor(0),
    mode = vim.api.nvim_get_mode().mode }
  local source = opts.source or { items = {} }
  local self = setmetatable({
    title = opts.title or '', hint = opts.hint, source = source, row = opts.row or function(it) return tostring(it) end,
    detail = opts.detail, on_pick = opts.on_pick, on_close = opts.on_close, origin = origin,
    query = opts.query or '', items = {}, filtered = {}, sel = 1, seq = 0, busy = false, closed = false,
  }, Picker)
  if not source.fetch then
    source.filter = source.filter or M.filter
    self.items = source.items or {}
    self.filtered = source.filter(self.items, self.query)
  end

  local width = math.min(math.floor(vim.o.columns * 0.8), 120)
  self.width = width
  local list_h = self:async() and math.max(5, math.floor(vim.o.lines * 0.3))
    or math.min(math.max(#self.items, 1), math.max(5, math.floor(vim.o.lines * 0.5)))
  local detail_h = opts.detail and 6 or 0
  -- the box: border, query, rule, list, (rule, detail), border
  local fixed = 4 + (opts.detail and detail_h + 1 or 0)
  list_h = math.max(1, math.min(list_h, vim.o.lines - fixed - 2))
  local total = fixed + list_h
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.max(1, math.floor((vim.o.lines - total - 2) / 2))
  local function float(buf, enter, r, h, b)
    return vim.api.nvim_open_win(buf, enter, { relative = 'editor', row = r, col = col, width = width, height = h,
      style = 'minimal', border = b, zindex = 50 })
  end

  self.search_buf = vim.api.nvim_create_buf(false, true)
  self.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.list_buf].modifiable = false
  vim.api.nvim_buf_set_lines(self.search_buf, 0, -1, false, { self.query })
  self.list_win = float(self.list_buf, false, row + 3, list_h, border(false, opts.detail ~= nil))
  vim.wo[self.list_win].cursorline = false
  vim.wo[self.list_win].wrap = false
  if opts.detail then
    self.detail_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self.detail_buf].modifiable = false
    self.detail_win = float(self.detail_buf, false, row + 4 + list_h, detail_h, border(false, false))
    vim.wo[self.detail_win].wrap = true
    vim.wo[self.detail_win].linebreak = true
  end
  self.search_win = float(self.search_buf, true, row, 1, border(true, true))
  self:set_busy(false)
  self.busy = false
  vim.api.nvim_win_set_config(self.search_win, { title = ' ' .. self.title .. ' ', title_pos = 'left' })
  pcall(vim.api.nvim_win_set_cursor, self.search_win, { 1, #self.query })

  local sb = self.search_buf
  vim.b[sb].completion = false
  local function map(lhs, fn) vim.keymap.set({ 'i', 'n' }, lhs, fn, { buffer = sb, nowait = true }) end
  map('<CR>', function() self:confirm() end)
  map('<Esc>', function() self:close() end)
  map('<C-c>', function() self:close() end)
  map('<Down>', function() self:move(1) end)
  map('<C-n>', function() self:move(1) end)
  map('<Up>', function() self:move(-1) end)
  map('<C-p>', function() self:move(-1) end)
  for lhs, fn in pairs(opts.keys or {}) do
    map(lhs, function() fn(self:selected(), self) end)
  end
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, { buffer = sb, callback = function()
    local q = vim.api.nvim_buf_get_lines(sb, 0, 1, false)[1] or ''
    if not self.closed and q ~= self.query then self:set_query(q) end
  end })
  vim.api.nvim_create_autocmd('BufLeave', { buffer = sb, once = true, callback = function()
    vim.schedule(function() self:close() end)
  end })

  if self:async() then
    self.timer = vim.uv.new_timer()
    self:render()
    self:fetch()
  else
    self:render()
  end
  vim.cmd.startinsert({ bang = true })
  return self
end
return M
