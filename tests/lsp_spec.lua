-- tests/lsp_spec.lua
local H = require('helpers')

local function blog()
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  return dst
end

local function attached(buf)
  return H.wait(5000, function() return require('alder.lsp').client(buf) ~= nil and vim.b[buf].alder_lsp end)
end

test('lsp: attaches on FileType alder and reuses the client per root', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local a = vim.api.nvim_get_current_buf()
  assert(attached(a), 'not attached')
  vim.cmd.edit(root .. '/app/Post.alder')
  local b = vim.api.nvim_get_current_buf()
  assert(attached(b))
  assert(require('alder.lsp').client(a).id == require('alder.lsp').client(b).id, 'two servers for one root')
end)

test('lsp: diagnostics while typing', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local l = vim.fn.search('^perPage = 10') - 1
  vim.api.nvim_buf_set_lines(buf, l, l + 1, false, { 'perPage = "ten"' })
  assert(H.wait(5000, function()
    for _, d in ipairs(vim.diagnostic.get(buf)) do if d.code == 'E0003' then return true end end
  end), 'no E0003 from the server')
end)

test('lsp: hover via vim.lsp.buf_request_sync', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  H.wait(3000, function() return false end) -- let the first analysis land
  vim.fn.search('lastPage then')
  local res = vim.lsp.buf_request_sync(buf, 'textDocument/hover', vim.lsp.util.make_position_params(0, 'utf-8'), 3000)
  local text = ''
  for _, r in pairs(res or {}) do if r.result then text = r.result.contents.value end end
  assert(text:find('lastPage : Int', 1, true), text)
end)

test('lsp: no check-on-save while attached', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local ran = false
  local check = require('alder.check')
  local orig = check.run
  check.run = function() ran = true end
  vim.cmd.write()
  check.run = orig
  assert(not ran, 'alder check ran on save with the server attached')
end)

test('lsp: opts.lsp = false keeps CLI mode', function()
  local saved = require('alder.config').options
  require('alder.config').set({ lsp = false, path = saved.path })
  local root = blog()
  vim.cmd.edit(root .. '/app/Post.alder')
  local buf = vim.api.nvim_get_current_buf()
  H.wait(500, function() return false end)
  assert(require('alder.lsp').client(buf) == nil)
  require('alder.config').options = saved
end)

test('lsp: a killed server is reported once', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Post.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local messages, restore = H.capture_notify()
  require('alder.lsp').client(buf):stop(true)
  H.wait(3000, function() return #messages > 0 end)
  restore()
  assert(H.wait(3000, function() return not vim.b[buf].alder_lsp end), 'b:alder_lsp still set after the server died')
  local n = 0
  for _, m in ipairs(messages) do if m.msg == 'alder lsp stopped — :checkhealth alder' then n = n + 1 end end
  assert(n == 1, vim.inspect(messages))
end)

test('lsp: a request the closing client refuses calls on_err, never cb', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Post.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local c = require('alder.lsp').client(buf)
  local orig = c.request
  c.request = function() return false end
  local got, called = nil, false
  require('alder.lsp').request(buf, 'alder/generators', {}, function() called = true end, function(err) got = err end)
  c.request = orig
  assert(not called and got and got.message == 'alder lsp stopped — :checkhealth alder', vim.inspect(got))
end)

local TOKENS = 'textDocument/semanticTokens/full'

test('lsp: semantic tokens are stripped by default and the offer is recorded', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Show.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local c = require('alder.lsp').client(buf)
  assert(not c:supports_method(TOKENS, buf), 'semantic tokens still advertised')
  local st
  for _, s in ipairs(require('alder.lsp').status()) do if s.root == c.root_dir then st = s end end
  assert(st and st.semantic_tokens == true, vim.inspect(st))
  H.wait(1500, function() return false end) -- time for a token request, had one been sent
  local got = vim.lsp.semantic_tokens.get_at_pos(buf, 0, 0)
  assert(not got or #got == 0, vim.inspect(got))
end)

test('lsp: opts.semantic_tokens = true keeps the server tokens', function()
  local saved = require('alder.config').options
  require('alder.config').set({ semantic_tokens = true, path = saved.path })
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Show.alder')
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = pcall(function()
    assert(attached(buf))
    assert(require('alder.lsp').client(buf):supports_method(TOKENS, buf), 'semantic tokens stripped despite the opt in')
    assert(H.wait(5000, function()
      local got = vim.lsp.semantic_tokens.get_at_pos(buf, 0, 0)
      return got and #got > 0
    end), 'no server token on `module`')
  end)
  require('alder.config').options = saved
  assert(ok, err)
end)

-- search_buf opens a blog module and appends a signature a and a definition b (a typed hole); returns buf and b's 0-based row.
local function search_buf(a, b)
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, n, n, false, { '', a, b })
  return buf, n + 2 -- 0-based row of the hole line b
end

local function wait_picker()
  local search = require('alder.search')
  assert(H.wait(8000, function() return search.state ~= nil end), 'picker did not open')
  return search.state
end

test('lsp: initialize declares experimental.alderSearch', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local c = require('alder.lsp').client(buf)
  assert(c.config.capabilities.experimental.alderSearch == true, vim.inspect(c.config.capabilities.experimental))
end)

test('lsp: search finds Text.split by type', function()
  local root = blog()
  vim.cmd.edit(root .. '/app/Posts/Index.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(attached(buf))
  local res, found
  H.wait(10000, function() -- the server answers once its first analysis has landed
    res = vim.lsp.buf_request_sync(buf, 'alder/search', { query = 'Text -> Text -> List Text', uri = vim.uri_from_bufnr(buf) }, 3000)
    for _, r in pairs(res or {}) do
      for _, hit in ipairs(r.result and r.result.results or {}) do
        if hit.module == 'Text' and hit.name == 'split' then found = true end
      end
    end
    return found
  end)
  assert(found, vim.inspect(res))
end)

test('lsp: search on a hole fills it and lands on the new hole', function()
  local buf, row = search_buf('holeTest : List Text', 'holeTest = ?h')
  vim.api.nvim_win_set_cursor(0, { row + 1, 11 }) -- on the ?
  -- the server must have analysed the edit (a hole prefill): ask until it answers one
  local ready = H.wait(10000, function()
    local r = vim.lsp.buf_request_sync(buf, 'alder/search', { query = '', uri = vim.uri_from_bufnr(buf),
      position = { line = row, character = 11 } }, 3000)
    for _, v in pairs(r or {}) do if v.result and (v.result.query or '') ~= '' then return true end end
  end)
  assert(ready, 'the server never saw the hole')
  require('alder.search').open({})
  local p = wait_picker()
  assert((p.query or ''):find('List Text', 1, true), 'no hole prefill: ' .. tostring(p.query))
  -- the prefilled list: pick Text.lines, which takes an argument, so the fill leaves a new hole
  local idx
  assert(H.wait(8000, function()
    for i, it in ipairs(p.filtered or {}) do if it.module == 'Text' and it.name == 'lines' then idx = i end end
    return idx
  end), 'Text.lines not listed')
  p:move(idx - p.sel)
  p:confirm()
  local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  assert(H.wait(8000, function() return text():find('holeTest = Text.lines ?', 1, true) end), text():sub(-200))
  local l = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  assert(l:find('^holeTest = Text.lines %?'), l)
  assert(H.wait(2000, function()
    local cur = vim.api.nvim_win_get_cursor(0)
    return cur[1] == row + 1 and l:sub(cur[2] + 1, cur[2] + 1) == '?'
  end), 'the cursor is not on the new hole: ' .. vim.inspect(vim.api.nvim_win_get_cursor(0)) .. ' ' .. l)
end)

test('lsp: the code action Search for opens the picker at the hole', function()
  local buf, row = search_buf('holeAct : List Text', 'holeAct = ?h')
  local origin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(origin, { 1, 0 })
  local pos = { line = row, character = 10 }
  local action, res
  H.wait(10000, function() -- once the server has analysed the edited buffer
    res = vim.lsp.buf_request_sync(buf, 'textDocument/codeAction', {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      range = { start = pos, ['end'] = pos },
      context = { diagnostics = {} },
    }, 3000)
    for _, r in pairs(res or {}) do
      for _, a in ipairs(r.result or {}) do
        if a.title:find('^Search for') then action = a end
      end
    end
    return action
  end)
  assert(action, 'no Search for action: ' .. vim.inspect(res))
  assert(action.command and action.command.command == 'alder.search', vim.inspect(action))
  local c = require('alder.lsp').client(buf)
  c:exec_cmd(action.command, { bufnr = buf })
  local p = wait_picker()
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(origin), { 1, 0 }), 'the cursor moved')
  assert((p.query or ''):find('List Text', 1, true), 'no hole prefill: ' .. tostring(p.query))
end)
