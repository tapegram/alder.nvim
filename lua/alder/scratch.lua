-- alder/scratch: render the server's watch results of a *scratch.alder file as virtual text.
local M = {}

M.ns = vim.api.nvim_create_namespace('alder.scratch')
-- [buf] = { version = n, ids = { [watch index] = extmark id }, watches = {...}, specs = {...}, note_id = id }
M.marks = {}
local warned = {}

local MAX_VLINES, MAX_BYTES = 8, 2048
local PENDING, VALUE, ERROR, NOTE = 'AlderScratchPending', 'AlderScratchValue', 'AlderScratchError', 'AlderScratchNote'

local function split(s) return vim.split(s, '\n', { plain = true }) end

-- spec_of builds {virt_text, virt_lines} (chunk lists) for one watch.
local function spec_of(w, phase)
  local note = w.note and w.note ~= '' and w.note or nil
  local typ = w.type and w.type ~= '' and w.type or nil
  if w.error and w.error ~= '' then
    return { { { '  ✗ ' .. split(w.error)[1], ERROR } } }
  end
  if note and typ then -- an effect watch: its value and note are final from the types phase on
    local v = split(w.value or '')[1]
    return { { { ('  %s : %s  (%s)'):format(v, typ, note), NOTE } } }
  end
  if note then return { { { '  ' .. note, NOTE } } } end
  if phase == 'types' or w.value == nil then
    return { { { '  : ' .. (typ or '?') .. '  …', PENDING } } }
  end
  local lines = split(w.value)
  local first = lines[1]
  if #first > MAX_BYTES then first = first:sub(1, MAX_BYTES) end
  local bytes = #first
  local vl = {}
  -- when every line fits in the virtual lines, show it whole; else leave one for the "more" line
  local limit = (#lines - 1 <= MAX_VLINES) and MAX_VLINES or (MAX_VLINES - 1)
  for i = 2, #lines do
    if #vl >= limit or bytes + #lines[i] > MAX_BYTES then break end
    bytes = bytes + #lines[i]
    vl[#vl + 1] = { { lines[i], VALUE } }
  end
  local hidden = #lines - 1 - #vl
  if hidden > 0 then
    vl[#vl + 1] = { { ('… (%d more lines, <leader>ao to open)'):format(hidden), VALUE } }
  end
  local head = '  ⇒ ' .. first .. (typ and (' : ' .. typ) or '')
  if w.truncated then head = head .. '  (truncated at 64 KB)' end
  return { { { head, VALUE } }, #vl > 0 and vl or nil }
end

local function dimmed(chunks)
  if not chunks then return nil end
  local out = {}
  for i, c in ipairs(chunks) do out[i] = { c[1], PENDING } end
  return out
end

local function dim_spec(spec)
  local vl
  if spec[2] then
    vl = {}
    for i, l in ipairs(spec[2]) do vl[i] = dimmed(l) end
  end
  return { dimmed(spec[1]), vl }
end

local function opts_for(spec, id, stale)
  if stale then spec = dim_spec(spec) end
  return { id = id, virt_text = spec[1], virt_text_pos = 'eol', virt_lines = spec[2], strict = false }
end

local function extra(buf, params, m, stale)
  local text, hl
  if params.error and params.error ~= '' then text, hl = params.error, ERROR
  elseif params.note and params.note ~= '' then text, hl = params.note, NOTE
  elseif params.warning and params.warning ~= '' and not warned[buf] then
    text, hl = params.warning, NOTE
    warned[buf] = true
  end
  if not text then
    if m.note_id then pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, m.note_id) m.note_id = nil end
    return
  end
  m.note_id = vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, {
    id = m.note_id, virt_text = { { '  ' .. split(text)[1], stale and PENDING or hl } }, virt_text_pos = 'eol', strict = false,
  })
end

local function dim_all(buf)
  local m = M.marks[buf]
  if not m or not vim.api.nvim_buf_is_valid(buf) then return end
  m.stale = true
  for i, id in pairs(m.ids) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, id, {})
    if pos[1] then
      vim.api.nvim_buf_set_extmark(buf, M.ns, pos[1], 0, opts_for(m.specs[i], id, true))
    end
  end
end

local function register(buf, m)
  if m.autocmd then return end
  m.autocmd = true
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf, once = true,
    callback = function() M.marks[buf] = nil; warned[buf] = nil end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function() if M.marks[buf] and next(M.marks[buf].ids) then dim_all(buf) end end,
  })
end

local function place(buf, params, m, fresh)
  local stale = params.version ~= vim.lsp.util.buf_versions[buf]
  local n = vim.api.nvim_buf_line_count(buf)
  m.watches, m.specs = params.watches or {}, {}
  for i, w in ipairs(m.watches) do
    local spec = spec_of(w, params.phase)
    m.specs[i] = spec
    local id = m.ids[i]
    local pos = id and vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, id, {})
    if id and pos and pos[1] then
      vim.api.nvim_buf_set_extmark(buf, M.ns, pos[1], 0, opts_for(spec, id, stale))
    else
      local row = math.max(0, math.min(w.line - 1, n - 1))
      m.ids[i] = vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, opts_for(spec, nil, stale))
    end
  end
  extra(buf, params, m, stale)
  m.stale = stale
end

function M.render(buf, params)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local current = vim.lsp.util.buf_versions[buf]
  local m = M.marks[buf]
  if params.phase == 'types' then
    if params.version ~= current then return end
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    m = { version = params.version, ids = {}, watches = {}, specs = {}, autocmd = m and m.autocmd }
    M.marks[buf] = m
    register(buf, m)
    place(buf, params, m)
  elseif params.phase == 'values' then
    if m and m.version == params.version then
      place(buf, params, m)
    elseif params.version == current then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      m = { version = params.version, ids = {}, watches = {}, specs = {}, autocmd = m and m.autocmd }
      M.marks[buf] = m
      register(buf, m)
      place(buf, params, m)
    end
  end
end

function M.handler(err, params, _)
  if err or not params or not params.uri then return end
  -- look the buffer up; vim.uri_to_bufnr would create one for a uri nobody has open
  local fname = vim.fs.normalize(vim.uri_to_fname(params.uri))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == fname then
      return M.render(buf, params)
    end
  end
end

-- value_at is the watch whose lines contain row (1-based), following the marks through edits.
function M.value_at(buf, row)
  local m = M.marks[buf]
  if not m then return nil end
  for i, id in pairs(m.ids) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, id, {})
    local w = m.watches[i]
    if pos[1] and w then
      local start = pos[1] + 1
      local last = start + math.max(0, (w.end_ or w['end'] or w.line) - w.line)
      if row >= start and row <= last then return w end
    end
  end
  return nil
end

function M.open_value()
  local buf = vim.api.nvim_get_current_buf()
  local w = M.value_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not w then
    vim.notify('alder: no scratch value here', vim.log.levels.INFO)
    return
  end
  local text = w.error and w.error ~= '' and w.error or w.value or w.note or ''
  local lines = split(text)
  if w.type and w.type ~= '' then lines[#lines + 1] = ': ' .. w.type end
  return vim.lsp.util.open_floating_preview(lines, 'text', { border = 'rounded', focusable = true, title = ' scratch ' })
end

-- TEMPLATE is the text of a new scratch.alder (internal/scaffold/files/scratch.alder in alder).
M.TEMPLATE = [[-- A scratch file: each `> expr` line is evaluated. Run `alder scratch --watch` to see results on save.
-- Everything else is ordinary Alder: define values and helpers here, then watch them.
-- Put `in Module` on the first line to work inside an app module, with its names unqualified.

> 1 + 1
]]

local warned_in = false
function M.reset_warned() warned_in = false end

-- is_scratch is whether buf is a scratch.alder file.
function M.is_scratch(buf)
  return vim.api.nvim_buf_get_name(buf == 0 and vim.api.nvim_get_current_buf() or buf):match('scratch%.alder$') ~= nil
end

local function ensure(root)
  local path = root .. '/scratch.alder'
  if not vim.uv.fs_stat(path) then
    vim.fn.mkdir(root, 'p')
    local f = assert(io.open(path, 'w'))
    f:write(M.TEMPLATE)
    f:close()
  end
  return path
end

-- open edits <root>/scratch.alder, writing TEMPLATE first if it is missing.
function M.open(root)
  vim.cmd.edit(vim.fn.fnameescape(ensure(root)))
end

-- header_module is the module named by the file's `in` header (its first line of code), or nil.
local function header_module(buf)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 20, false)) do
    if l:match('%S') and not l:match('^%s*%-%-') then return l:match('^in%s+([%w%.]+)') end
  end
end

-- append adds lines as a watch at the end of <root>/scratch.alder and saves it (which runs it).
-- module is the sending buffer's module, or nil.
function M.append(root, lines, module)
  local path = ensure(root)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  local indent
  for _, l in ipairs(lines) do
    if l:match('%S') then
      local n = #l:match('^%s*')
      indent = indent and math.min(indent, n) or n
    end
  end
  local out = {}
  for _, l in ipairs(lines) do out[#out + 1] = l:sub((indent or 0) + 1) end
  while #out > 0 and not out[#out]:match('%S') do out[#out] = nil end
  if #out == 0 then return end
  local add = { '', '> ' .. out[1] }
  for i = 2, #out do add[#add + 1] = out[i] == '' and '' or ('    ' .. out[i]) end
  local n = vim.api.nvim_buf_line_count(buf)
  -- a file that already ends in a blank line needs no separator of ours
  if n > 0 and vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] == '' then table.remove(add, 1) end
  vim.api.nvim_buf_set_lines(buf, n, n, false, add)
  if vim.bo[buf].filetype ~= 'alder' then vim.bo[buf].filetype = 'alder' end
  vim.api.nvim_buf_call(buf, function() vim.cmd('silent write') end)
  if vim.fn.bufwinid(buf) == -1 then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd('botright sbuffer ' .. buf)
    vim.api.nvim_set_current_win(cur)
  end
  if module and not warned_in and header_module(buf) ~= module then
    warned_in = true
    vim.notify(('alder: scratch.alder is not "in %s"; names from %s need qualifying (add "in %s" as its first line)'):format(module, module, module), vim.log.levels.WARN)
  end
end

-- send_current sends the current line ('n') or the visual selection ('x') to scratch.alder.
function M.send_current(mode)
  local r = require('alder.root').require_for_buf(0)
  if not r then return end
  local lines
  if mode == 'x' then
    vim.cmd('normal! \27')
    lines = vim.api.nvim_buf_get_lines(0, vim.fn.line("'<") - 1, vim.fn.line("'>"), false)
  else
    lines = { vim.api.nvim_get_current_line() }
  end
  local cur = vim.api.nvim_get_current_buf()
  local module = not M.is_scratch(cur) and vim.bo[cur].filetype == 'alder' and require('alder.buf').module_name(cur) or nil
  M.append(r, lines, module)
end

return M
