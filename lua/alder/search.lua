-- search: the search picker (<leader>af, :AlderSearch) — find a function by name or by type
-- through the language server (`alder/search`), read its signature and doc, insert it or fill the
-- typed hole under the cursor with it (`alder/searchEdit`), or jump to an app result's
-- declaration. The server's results are shown as given: this module never filters, ranks or
-- builds an edit when there is a server, and never looks for holes itself.
local picker = require('alder.picker')
local ui = require('alder.ui')

local M = {}

-- M.state is the open picker (alder.picker), nil when none is open.
M.state = nil

M.HINT = 'Search by name or type — e.g. split, Text., Text -> Int, : List Text'
M.OLD = 'this alder has no search (update alder: go install ./cmd/alder in the alder repo, then :LspRestart)'
local METHOD_NOT_FOUND = -32601
local CANCELLED = -32800

-- label is how a result is shown: Module.name, or the bare name for the Prelude.
function M.label(r)
  if r.module == 'Prelude' or not r.module or r.module == '' then return r.name end
  return r.module .. '.' .. r.name
end

-- results and note_of read a reply (already through ui.plain); an empty note is no note.
local function results(reply)
  return (reply and reply.results) or {}
end

local function note_of(reply)
  local n = reply and reply.note
  if n == '' then return nil end
  return n
end

-- detail renders the detail pane: the label with its tags (source, effect, a match other than
-- general) right-aligned to width, the whole signature, the doc lines (none when blank).
local function detail(width)
  return function(r)
    local tags = { r.source }
    if r.effect and r.effect ~= '' then tags[#tags + 1] = r.effect end
    if r.match and r.match ~= '' and r.match ~= 'general' then tags[#tags + 1] = r.match end
    local tag = table.concat(vim.tbl_filter(function(t) return t and t ~= '' end, tags), '  ')
    local label = M.label(r)
    local gap = math.max(2, width - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(tag))
    local head = label .. string.rep(' ', gap) .. tag
    local lines = { head, r.signature or '' }
    local marks = { { row = 1, col = 0, end_col = #label, hl = 'Title' },
      { row = 1, col = #head - #tag, hl = 'Comment' } }
    local doc = r.doc or ''
    if vim.trim(doc) ~= '' then vim.list_extend(lines, vim.split(vim.trim(doc), '\n', { plain = true })) end
    return lines, marks
  end
end

-- the picker's width (alder.picker's): the detail header is right-aligned to it.
local function pane_width() return math.min(math.floor(vim.o.columns * 0.8), 120) end

-- wire is byte column col of buf's row (0-based) as a position in enc.
local function wire(buf, row, col, enc)
  local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  col = math.min(col, #text)
  return { line = row, character = vim.str_utfindex(text, enc, col, false) }
end

-- byte is a position in enc as a 0-based byte column of buf's line.
local function byte(buf, pos, enc)
  local text = vim.api.nvim_buf_get_lines(buf, pos.line, pos.line + 1, false)[1] or ''
  return vim.str_byteindex(text, enc, pos.character, false)
end

-- after is the byte column just past the character at col (0-based) of row: where a normal-mode
-- insert goes (as `a` and `p` do); 0 on an empty line.
local function after(buf, row, col)
  local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  if text == '' then return 0 end
  col = math.min(col, #text - 1)
  return math.min(#text, col + vim.str_utf_end(text, col + 1) + 1)
end

-- complain reports a failed request: an alder without search gets the update message (never the
-- raw "unknown method"), a cancelled one nothing, any other error its own message.
local function complain(err)
  if err.code == METHOD_NOT_FOUND then return vim.notify(M.OLD, vim.log.levels.WARN) end
  if err.code == CANCELLED then return end
  vim.notify('alder search: ' .. tostring(err.message), vim.log.levels.ERROR)
end

-- set_cursor puts win's cursor at {row, col}, and again once leaving the picker's insert mode
-- has taken effect (it moves the cursor a column) if that window still shows buf.
local function set_cursor(win, buf, pos)
  if not vim.api.nvim_win_is_valid(win) then return end
  pcall(vim.api.nvim_win_set_cursor, win, pos)
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_get_current_win() == win then
      pcall(vim.api.nvim_win_set_cursor, win, pos)
    end
  end)
end

-- insert_text writes text into the origin buffer as plain text (no document for the server):
-- after the cursor character in normal mode, at the caret from insert mode.
local function insert_text(o, text)
  if not vim.api.nvim_buf_is_valid(o.buf) then return end
  if not vim.bo[o.buf].modifiable then
    return vim.notify('alder: this buffer is not modifiable', vim.log.levels.WARN)
  end
  local row, col = o.cursor[1] - 1, o.cursor[2]
  if not o.insert then col = after(o.buf, row, col) end
  vim.api.nvim_buf_set_text(o.buf, row, col, row, col, { text })
  set_cursor(o.win, o.buf, { row + 1, col + #text })
end

-- fill asks the server for the edit that writes r at the open position (on a hole) or at the
-- cursor, applies it as given and puts the cursor where the server says.
local function fill(o, client, r)
  local doc = o.doc
  if not vim.bo[o.buf].modifiable then
    return vim.notify('alder: this buffer is not modifiable', vim.log.levels.WARN)
  end
  local enc = client.offset_encoding or 'utf-16'
  local position = doc.position
  if not o.on_hole then
    local row, col = o.cursor[1] - 1, o.cursor[2]
    if not o.insert then col = after(o.buf, row, col) end
    position = wire(o.buf, row, col, enc)
  end
  local params = { uri = doc.uri, position = position, module = r.module, name = r.name, kind = r.kind }
  if r.args ~= nil then params.args = r.args end
  local sent = client:request('alder/searchEdit', params, function(err, reply)
    if err then return complain(err) end
    reply = ui.plain(reply)
    if type(reply) ~= 'table' or not reply.cursor or not reply.edit then
      return vim.notify(M.OLD, vim.log.levels.WARN)
    end
    vim.lsp.util.apply_workspace_edit(reply.edit, enc)
    local bufnr = vim.uri_to_bufnr(doc.uri)
    set_cursor(o.win, bufnr, { reply.cursor.line + 1, byte(bufnr, reply.cursor, enc) })
  end, o.buf)
  if sent == false then vim.notify('alder lsp stopped — :checkhealth alder', vim.log.levels.WARN) end
end

-- jump opens an app result's declaration.
local function jump(r, enc)
  vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(r.uri)))
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_win_set_cursor, 0, { r.range.start.line + 1, byte(buf, r.range.start, enc) })
  vim.cmd('normal! zv')
end

-- show opens the picker with the open request's reply: its query in the box and its results as
-- the starting list (the picker's first fetch hands them back instead of asking again).
local function show(o, client, first)
  local enc = client.offset_encoding or 'utf-16'
  local start = { results(first), note_of(first) }
  local jumping = false
  local function fetch(q, done)
    if start then
      local s = start
      start = nil
      return done(s[1], s[2])
    end
    if q == '' then return done({}) end -- an empty box: the hint (the server has nothing for it)
    local sent = client:request('alder/search', { query = q, uri = o.doc and o.doc.uri }, function(err, reply)
      if err then
        if err.code == METHOD_NOT_FOUND then return done({}, M.OLD) end
        return done({}, 'alder search: ' .. tostring(err.message))
      end
      reply = ui.plain(reply)
      done(results(reply), note_of(reply))
    end, o.buf)
    if sent == false then done({}, 'alder lsp stopped — :checkhealth alder') end
  end
  local p
  p = picker.open({
    title = 'Search',
    query = (first and first.query) or '',
    hint = M.HINT,
    source = { fetch = fetch },
    row = function(r) return M.label(r), r.signature end,
    detail = detail(pane_width()),
    on_pick = function(r)
      if jumping then return jump(r, enc) end
      if o.doc then return fill(o, client, r) end
      insert_text(o, M.label(r))
    end,
    on_close = function() if M.state == p then M.state = nil end end,
    keys = {
      ['<C-]>'] = function(r, pk)
        if not r then return end
        if not (r.uri and r.range) then
          return vim.notify('alder: the standard library has no source to open', vim.log.levels.INFO)
        end
        jumping = true
        pk:confirm()
      end,
    },
  })
  M.state = p
  return p
end

-- open opens the picker. opts.query is the starting text; opts.at = {buf, position} opens it at
-- that position (the hole of the "Search for" code action) instead of the cursor's.
function M.open(opts)
  opts = opts or {}
  if M.state then M.state:close() end
  local win = vim.api.nvim_get_current_win()
  local buf = (opts.at and opts.at.buf) or vim.api.nvim_get_current_buf()
  local o = { win = win, buf = buf, cursor = vim.api.nvim_win_get_cursor(win),
    insert = vim.api.nvim_get_mode().mode:find('^i') ~= nil }
  local lsp = require('alder.lsp')
  local root = require('alder.project').root(buf)
  local client = root and lsp.project_client(root, buf)
  if not client then
    -- the `alder search --json` fallback comes here
    return vim.notify('alder: the language server is not running (:checkhealth alder)', vim.log.levels.WARN)
  end
  local enc = client.offset_encoding or 'utf-16'
  if vim.api.nvim_buf_get_name(buf):match('%.alder$') and lsp.client(buf) == client then
    local position = opts.at and opts.at.position
      or wire(buf, o.cursor[1] - 1, o.cursor[2], enc)
    o.doc = { uri = vim.uri_from_bufnr(buf), position = position }
  end
  local query = opts.query or ''
  local params = { query = query }
  if o.doc then params.uri, params.position = o.doc.uri, o.doc.position end
  local sent = client:request('alder/search', params, function(err, reply)
    if err then return complain(err) end
    reply = ui.plain(reply) or {}
    o.on_hole = o.doc ~= nil and query == '' and (reply.query or '') ~= ''
    -- the window may have gone while the request was out
    if not vim.api.nvim_win_is_valid(win) then return end
    show(o, client, reply)
  end, buf)
  if sent == false then vim.notify('alder lsp stopped — :checkhealth alder', vim.log.levels.WARN) end
end

return M
