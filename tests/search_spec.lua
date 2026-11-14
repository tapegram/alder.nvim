local H = require('helpers')
local search = require('alder.search')

local HINT = 'Search by name or type — e.g. split, Text., Text -> Int, : List Text'
local OLD = 'this alder has no search (update alder: go install ./cmd/alder in the alder repo, then :LspRestart)'

local split = { name = 'split', module = 'Text', kind = 'function', signature = 'Text -> Text -> List Text',
  doc = 'Splits a text wherever the\nseparator appears.', source = 'stdlib', match = 'general', effect = vim.NIL }
local lines_ = { name = 'lines', module = 'Text', kind = 'function', signature = 'Text -> List Text',
  doc = '', source = 'stdlib', match = 'reordered', args = 0 }
local just = { name = 'Just', module = 'Prelude', kind = 'constructor', signature = 'a -> Maybe a', doc = vim.NIL,
  source = 'stdlib' }

-- fake is a language client whose requests are recorded; answers[method](params) -> err, result
-- answers at once, else the test answers with reply(i, err, result).
local function fake(enc)
  local c = { offset_encoding = enc or 'utf-8', sent = {}, answers = {} }
  function c:request(method, params, handler, buf)
    local r = { method = method, params = params, handler = handler, buf = buf }
    table.insert(self.sent, r)
    local a = self.answers[method]
    if a then
      local err, result = a(params)
      if err or result then r.answered = true; handler(err, result) end
    end
    return true
  end
  function c:reply(i, err, result)
    local r = assert(self.sent[i], 'no request ' .. i)
    r.answered = true
    r.handler(err, result)
  end
  return c
end

-- env sets up a buffer (an .alder document attached to the fake client unless plain) with text and
-- the cursor at {row, col}, and stubs the project and the client. run(f) runs f(env) and restores.
local function env(opts)
  local lsp, project = require('alder.lsp'), require('alder.project')
  local e = { client = fake(opts.enc), root = H.tmpdir() }
  vim.cmd.enew()
  e.buf = vim.api.nvim_get_current_buf()
  e.win = vim.api.nvim_get_current_win()
  if not opts.plain then vim.api.nvim_buf_set_name(e.buf, e.root .. '/app/Main.alder') end
  vim.api.nvim_buf_set_lines(e.buf, 0, -1, false, opts.lines or { '' })
  vim.api.nvim_win_set_cursor(0, opts.cursor or { 1, 0 })
  e.uri = vim.uri_from_bufnr(e.buf)
  local saved = { lsp.project_client, lsp.client, project.root }
  lsp.project_client = function() return e.client end
  lsp.client = function(b) if not opts.plain and b == e.buf then return e.client end end
  project.root = function() return e.root end
  function e.run(f)
    local ok, err = pcall(f, e)
    if search.state then search.state:close() end
    lsp.project_client, lsp.client, project.root = saved[1], saved[2], saved[3]
    assert(ok, err)
  end
  return e
end

local function reply(query, results, note)
  return { query = query, mode = 'name', note = note or '', results = results or {} }
end

local function sent(e, method)
  local out = {}
  for _, r in ipairs(e.client.sent) do if r.method == method then out[#out + 1] = r end end
  return out
end

local function line(buf, n) return vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] end

test('search: Prelude label is bare', function()
  assert(search.label(just) == 'Just', search.label(just))
  assert(search.label(split) == 'Text.split', search.label(split))
end)

test('search: opens empty with the hint', function()
  local e = env({ lines = { 'x = 1' }, cursor = { 1, 2 } })
  e.run(function()
    e.client.answers['alder/search'] = function() return nil, reply('', {}) end
    search.open({})
    local s = sent(e, 'alder/search')
    assert(#s == 1, vim.inspect(e.client.sent))
    assert(s[1].params.query == '' and s[1].params.uri == e.uri, vim.inspect(s[1].params))
    assert(vim.deep_equal(s[1].params.position, { line = 0, character = 2 }), vim.inspect(s[1].params))
    assert(search.state, 'no picker')
    assert(search.HINT == HINT, search.HINT)
    local text = H.float_text()
    assert(text:find('Search by name or type — e.g. split, Text.,', 1, true), text)
    H.wait(200, function() return false end)
    assert(#sent(e, 'alder/search') == 1, 'the on-open fetch sent a request: ' .. #sent(e, 'alder/search'))
  end)
end)

test('search: opens on a hole with its query and results', function()
  local e = env({ lines = { 'x = ?h' }, cursor = { 1, 4 } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.position then return nil, reply(': List Text', { lines_, split }) end
    end
    search.open({})
    local p = search.state
    assert(p and p.query == ': List Text', p and p.query)
    local text = H.float_text()
    assert(text:find(': List Text', 1, true) and text:find('Text.lines', 1, true) and text:find('Text.split', 1, true), text)
    -- the detail pane: the first result in the server's order, its tags, its signature
    assert(text:find('Text.lines +stdlib  reordered'), text)
    assert(not text:find('Splits a text', 1, true), text)
    p:move(1)
    text = H.float_text()
    assert(text:find('Text.split +stdlib\n'), text)
    assert(text:find('Splits a text wherever the\nseparator appears.', 1, true), text)
    H.wait(200, function() return false end)
    assert(#sent(e, 'alder/search') == 1, 'the starting list was fetched again')
    assert(H.float_text():find('Text.lines', 1, true), 'the starting list was replaced')
  end)
end)

test('search: typing replaces the list', function()
  local e = env({ lines = { 'x = 1' } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.query == '' then return nil, reply('', {}) end
    end
    search.open({})
    search.state:set_query('spl')
    assert(H.wait(1000, function() return #sent(e, 'alder/search') == 2 end), 'no request for spl')
    local r = sent(e, 'alder/search')[2]
    assert(r.params.query == 'spl' and r.params.uri == e.uri and r.params.position == nil, vim.inspect(r.params))
    e.client:reply(2, nil, reply('spl', { split }))
    local text = H.float_text()
    assert(text:find('Text.split', 1, true) and not text:find('Search by name', 1, true), text)
    search.state:set_query('Text -> Int')
    assert(H.wait(1000, function() return #sent(e, 'alder/search') == 3 end), 'no request for the type')
    e.client:reply(3, nil, reply('Text -> Int', {}, 'to search by type, start with `:`'))
    text = H.float_text()
    assert(text:find('to search by type', 1, true) and not text:find('Text.split', 1, true), text)
  end)
end)

test('search: a stale reply is dropped', function()
  local e = env({ lines = { 'x = 1' } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.query == '' then return nil, reply('', {}) end
    end
    search.open({})
    search.state:set_query('a')
    assert(H.wait(1000, function() return #sent(e, 'alder/search') == 2 end), 'no request for a')
    search.state:set_query('b')
    assert(H.wait(1000, function() return #sent(e, 'alder/search') == 3 end), 'no request for b')
    e.client:reply(3, nil, reply('b', { split }))
    e.client:reply(2, nil, reply('a', { just }))
    local text = H.float_text()
    assert(text:find('Text.split', 1, true) and not text:find('Just', 1, true), text)
  end)
end)

test('search: Enter on a hole applies the edit and moves the cursor to the new hole', function()
  local e = env({ lines = { 'module Main', 'x = ?h' }, cursor = { 2, 4 } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.position then return nil, reply(': List Text', { split }) end
    end
    e.client.answers['alder/searchEdit'] = function()
      return nil, { edit = { changes = { [e.uri] = {
        { range = { start = { line = 1, character = 4 }, ['end'] = { line = 1, character = 6 } }, newText = 'Text.split ?a ?b' },
        { range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 0 } }, newText = 'import Text\n' },
      } } }, cursor = { line = 2, character = 15 } }
    end
    search.open({})
    -- the query changes; on a hole Enter still fills it, at the open position
    search.state:set_query('split')
    assert(H.wait(1000, function() return #sent(e, 'alder/search') == 2 end), 'no request')
    e.client:reply(2, nil, reply('split', { split }))
    search.state:confirm()
    local s = sent(e, 'alder/searchEdit')
    assert(#s == 1, vim.inspect(e.client.sent))
    assert(vim.deep_equal(s[1].params, { uri = e.uri, position = { line = 1, character = 4 }, module = 'Text',
      name = 'split', kind = 'function' }), vim.inspect(s[1].params))
    assert(line(e.buf, 2) == 'import Text' and line(e.buf, 3) == 'x = Text.split ?a ?b', vim.inspect(vim.api.nvim_buf_get_lines(e.buf, 0, -1, false)))
    H.wait(100, function() return false end)
    assert(vim.api.nvim_get_current_win() == e.win)
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(e.win), { 3, 15 }), vim.inspect(vim.api.nvim_win_get_cursor(e.win)))
    assert(vim.api.nvim_get_mode().mode == 'n', vim.api.nvim_get_mode().mode)
    assert(search.state == nil, 'picker still open')
  end)
end)

local function edit_at(e, text)
  return function(p)
    local pos = p.position
    return nil, { edit = { changes = { [e.uri] = { { range = { start = pos, ['end'] = pos }, newText = text } } } },
      cursor = { line = pos.line, character = pos.character + #text } }
  end
end

test('search: Enter off a hole sends the position after the cursor character', function()
  for _, case in ipairs({
    { lines = { 'x = ' }, cursor = { 1, 3 }, want = 4, after = 'x = Text.split' },
    { lines = { '' }, cursor = { 1, 0 }, want = 0, after = 'Text.split' },
    { lines = { 'aé' }, cursor = { 1, 1 }, want = 2, after = 'aéText.split', enc = 'utf-16' },
  }) do
    local e = env({ lines = case.lines, cursor = case.cursor, enc = case.enc })
    e.run(function()
      e.client.answers['alder/search'] = function() return nil, reply('', {}) end
      e.client.answers['alder/searchEdit'] = edit_at(e, 'Text.split')
      search.open({})
      search.state:set_query('split')
      assert(H.wait(1000, function() return #sent(e, 'alder/search') == 2 end), 'no request')
      e.client:reply(2, nil, reply('split', { split }))
      search.state:confirm()
      local s = sent(e, 'alder/searchEdit')[1]
      assert(s and vim.deep_equal(s.params.position, { line = 0, character = case.want }), vim.inspect(s and s.params))
      assert(line(e.buf, 1) == case.after, line(e.buf, 1))
    end)
  end
end)

test('search: Enter sends args unchanged, 0 included', function()
  local e = env({ lines = { 'x = ?h' }, cursor = { 1, 4 } })
  e.run(function()
    e.client.answers['alder/search'] = function() return nil, reply(': List Text', { lines_ }) end
    search.open({})
    search.state:confirm()
    local s = sent(e, 'alder/searchEdit')[1]
    assert(s and s.params.args == 0, vim.inspect(s and s.params))
  end)
end)

test('search: cursor after a pick past non-ASCII text', function()
  local e = env({ enc = 'utf-16', lines = { 'x = "é😀" ++ ?h' }, cursor = { 1, 16 } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.position then return nil, reply(': Text', { split }) end
    end
    e.client.answers['alder/searchEdit'] = function()
      return nil, { edit = { changes = { [e.uri] = {
        { range = { start = { line = 0, character = 13 }, ['end'] = { line = 0, character = 15 } }, newText = 'Text.split ?a ?b' },
      } } }, cursor = { line = 0, character = 24 } }
    end
    search.open({})
    local open = sent(e, 'alder/search')[1]
    assert(vim.deep_equal(open.params.position, { line = 0, character = 13 }), vim.inspect(open.params))
    search.state:confirm()
    assert(line(e.buf, 1) == 'x = "é😀" ++ Text.split ?a ?b', line(e.buf, 1))
    H.wait(100, function() return false end)
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(e.win), { 1, 27 }), vim.inspect(vim.api.nvim_win_get_cursor(e.win)))
  end)
end)

test('search: a searchEdit error inserts nothing', function()
  local e = env({ lines = { 'x = ' }, cursor = { 1, 3 } })
  e.run(function()
    e.client.answers['alder/search'] = function() return nil, reply('', {}) end
    e.client.answers['alder/searchEdit'] = function() return { code = -32602, message = 'no function Text.split in the search index' } end
    search.open({})
    search.state:set_query('split')
    assert(H.wait(1000, function() return #sent(e, 'alder/search') == 2 end), 'no request')
    e.client:reply(2, nil, reply('split', { split }))
    local messages, restore = H.capture_notify()
    local ok, err = pcall(function() search.state:confirm() end)
    restore()
    assert(ok, err)
    assert(line(e.buf, 1) == 'x = ', line(e.buf, 1))
    assert(#messages == 1 and messages[1].msg == 'alder search: no function Text.split in the search index'
      and messages[1].level == vim.log.levels.ERROR, vim.inspect(messages))
  end)
end)

test('search: a reply without cursor gives the update message', function()
  local e = env({ lines = { 'x = ?h' }, cursor = { 1, 4 } })
  e.run(function()
    e.client.answers['alder/search'] = function() return nil, reply(': Text', { split }) end
    e.client.answers['alder/searchEdit'] = function()
      return nil, { changes = { [e.uri] = { { range = { start = { line = 0, character = 4 }, ['end'] = { line = 0, character = 6 } }, newText = 'Text.split' } } } }
    end
    search.open({})
    local messages, restore = H.capture_notify()
    local ok, err = pcall(function() search.state:confirm() end)
    restore()
    assert(ok, err)
    assert(line(e.buf, 1) == 'x = ?h', line(e.buf, 1))
    assert(#messages == 1 and messages[1].msg == OLD, vim.inspect(messages))
  end)
end)

test('search: -32601 gives the update message', function()
  local e = env({ lines = { 'x = 1' } })
  e.run(function()
    e.client.answers['alder/search'] = function() return { code = -32601, message = 'unknown method alder/search' } end
    local messages, restore = H.capture_notify()
    local ok, err = pcall(search.open, {})
    restore()
    assert(ok, err)
    assert(search.state == nil, 'a picker opened')
    assert(#messages == 1 and messages[1].msg == OLD, vim.inspect(messages))
  end)
end)

test('search: Esc restores cursor and mode', function()
  -- from normal mode
  local e = env({ lines = { 'one', 'x = 1' }, cursor = { 2, 2 } })
  e.run(function()
    e.client.answers['alder/search'] = function() return nil, reply('', {}) end
    search.open({})
    assert(search.state and vim.api.nvim_get_current_win() ~= e.win, 'picker did not take focus')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
    H.wait(100, function() return false end)
    assert(search.state == nil, 'picker still open')
    assert(vim.api.nvim_get_current_win() == e.win)
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(e.win), { 2, 2 }), vim.inspect(vim.api.nvim_win_get_cursor(e.win)))
    assert(vim.api.nvim_get_mode().mode == 'n', vim.api.nvim_get_mode().mode)
    assert(#sent(e, 'alder/searchEdit') == 0)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(e.buf, 0, -1, false), { 'one', 'x = 1' }))
  end)
  -- from insert mode (a user's mapping): <F3> records where Esc left us before the feed ends
  e = env({ lines = { 'x = 1' }, cursor = { 1, 3 } })
  e.run(function()
    e.client.answers['alder/search'] = function() return nil, reply('', {}) end
    local seen
    vim.keymap.set('i', '<F2>', function() search.open({}) end, { buffer = e.buf })
    vim.keymap.set('i', '<F3>', function()
      seen = { mode = vim.api.nvim_get_mode().mode, win = vim.api.nvim_get_current_win(), cursor = vim.api.nvim_win_get_cursor(0) }
    end, { buffer = e.buf })
    vim.api.nvim_feedkeys('i' .. vim.keycode('<F2><Esc><F3>'), 'x', false)
    assert(seen, 'F3 never ran in the buffer')
    assert(seen.mode == 'i' and seen.win == e.win, vim.inspect(seen))
    assert(vim.deep_equal(seen.cursor, { 1, 3 }), vim.inspect(seen.cursor))
    assert(vim.api.nvim_buf_get_lines(e.buf, 0, -1, false)[1] == 'x = 1')
  end)
end)

test('search: Enter from insert mode inserts at the caret', function()
  local e = env({ lines = { 'x = ' }, cursor = { 1, 4 } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.query == '' then return nil, reply('', {}) end
      return nil, reply(p.query, { split })
    end
    e.client.answers['alder/searchEdit'] = edit_at(e, 'Text.split')
    local seen
    vim.keymap.set('i', '<F2>', function() search.open({ query = 'split' }) end, { buffer = e.buf })
    vim.keymap.set('i', '<F3>', function()
      seen = { mode = vim.api.nvim_get_mode().mode, cursor = vim.api.nvim_win_get_cursor(0) }
    end, { buffer = e.buf })
    vim.api.nvim_feedkeys('A' .. vim.keycode('<F2><CR><F3>'), 'x', false)
    local s = sent(e, 'alder/searchEdit')[1]
    assert(s and vim.deep_equal(s.params.position, { line = 0, character = 4 }), vim.inspect(s and s.params))
    assert(line(e.buf, 1) == 'x = Text.split', line(e.buf, 1))
    assert(seen and seen.mode == 'i' and vim.deep_equal(seen.cursor, { 1, 14 }), vim.inspect(seen))
  end)
end)

test('search: C-] opens an app result / refuses stdlib', function()
  local e = env({ lines = { 'x = 1' } })
  local file = e.root .. '/app/Home.alder'
  H.write(file, 'module Home\n\n  page = é 1\n')
  local home = { name = 'page', module = 'Home', kind = 'value', signature = 'Html Msg', doc = '', source = 'app',
    effect = 'query', uri = vim.uri_from_fname(file), range = { start = { line = 2, character = 2 }, ['end'] = { line = 2, character = 6 } } }
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.query == '' then return nil, reply('', {}) end
      return nil, reply(p.query, { split, home })
    end
    search.open({ query = 'page' })
    local text = H.float_text()
    assert(text:find('Home.page', 1, true), text)
    local messages, restore = H.capture_notify()
    local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode('<C-]>'), 'x', false)
    restore()
    assert(ok, err)
    assert(search.state, 'the picker closed on a stdlib result')
    assert(#messages == 1 and messages[1].msg == 'alder: the standard library has no source to open'
      and messages[1].level == vim.log.levels.INFO, vim.inspect(messages))
    search.state:move(1)
    assert(H.float_text():find('Home.page +app  query'), H.float_text())
    vim.api.nvim_feedkeys(vim.keycode('<C-]>'), 'x', false)
    H.wait(100, function() return false end)
    assert(search.state == nil, 'picker still open')
    assert(vim.api.nvim_buf_get_name(0) == file, vim.api.nvim_buf_get_name(0))
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 2 }), vim.inspect(vim.api.nvim_win_get_cursor(0)))
  end)
end)

test('search: non-Alder buffer inserts the label', function()
  local e = env({ plain = true, lines = { 'see ' }, cursor = { 1, 3 } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.query == '' then return nil, reply('', {}) end
      return nil, reply(p.query, { just })
    end
    search.open({ query = 'Just' })
    local s = sent(e, 'alder/search')[1]
    assert(s.params.query == 'Just' and s.params.uri == nil and s.params.position == nil, vim.inspect(s.params))
    search.state:confirm()
    assert(#sent(e, 'alder/searchEdit') == 0, 'searchEdit sent for a plain buffer')
    assert(line(e.buf, 1) == 'see Just', line(e.buf, 1))
  end)
  -- an unmodifiable buffer: a warning, nothing inserted
  e = env({ plain = true, lines = { 'see ' }, cursor = { 1, 3 } })
  e.run(function()
    vim.bo[e.buf].modifiable = false
    e.client.answers['alder/search'] = function(p) return nil, reply(p.query, { just }) end
    search.open({ query = 'Just' })
    local messages, restore = H.capture_notify()
    local ok, err = pcall(function() search.state:confirm() end)
    restore()
    assert(ok, err)
    assert(line(e.buf, 1) == 'see ', line(e.buf, 1))
    assert(#messages == 1 and messages[1].msg == 'alder: this buffer is not modifiable'
      and messages[1].level == vim.log.levels.WARN, vim.inspect(messages))
  end)
end)

test('search: opts.at opens at the hole and leaves the cursor until a pick', function()
  local e = env({ lines = { 'x = 1', 'y = ?h' }, cursor = { 1, 0 } })
  e.run(function()
    e.client.answers['alder/search'] = function(p)
      if p.position and p.position.line == 1 then return nil, reply(': Int', { split }) end
      return nil, reply('', {})
    end
    search.open({ at = { buf = e.buf, position = { line = 1, character = 4 } } })
    assert(search.state and search.state.query == ': Int', 'not opened on the hole')
    search.state:close()
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(e.win), { 1, 0 }))
  end)
end)
