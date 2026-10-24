-- tests/scratch_spec.lua
local H = require('helpers')
local S = require('alder.scratch')

local function mkbuf(lines, version)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.lsp.util.buf_versions[buf] = version or 1
  return buf
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, S.ns, 0, -1, { details = true })
end

local function eol(m) -- the text of a mark's eol chunks
  local t = {}
  for _, c in ipairs(m[4].virt_text or {}) do t[#t + 1] = c[1] end
  return table.concat(t)
end

local function params(phase, version, watches, extra)
  return vim.tbl_extend('force', { uri = 'file:///x', version = version, phase = phase, watches = watches, ran = phase == 'values' }, extra or {})
end

local W = function(line, t) return vim.tbl_extend('force', { line = line, ['end'] = line, expr = '1 + 1' }, t) end

test('scratch: types then values', function()
  local buf = mkbuf({ '-- c', '', '> 1 + 1' })
  S.render(buf, params('types', 1, { W(3, { type = 'Int' }) }))
  local ms = marks(buf)
  assert(#ms == 1 and ms[1][2] == 2)
  assert(eol(ms[1]) == '  : Int  …', eol(ms[1]))
  S.render(buf, params('values', 1, { W(3, { type = 'Int', value = '2' }) }))
  ms = marks(buf)
  assert(#ms == 1 and eol(ms[1]) == '  ⇒ 2 : Int', eol(ms[1]))
  assert(ms[1][4].virt_text[1][2] == 'AlderScratchValue')
end)

test('scratch: values follow their watch after an edit', function()
  local buf = mkbuf({ '-- c', '', '> 1 + 1' })
  S.render(buf, params('types', 1, { W(3, { type = 'Int' }) }))
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '', '' })
  vim.lsp.util.buf_versions[buf] = 2
  S.render(buf, params('values', 1, { W(3, { type = 'Int', value = '2' }) }))
  local ms = marks(buf)
  assert(#ms == 1 and ms[1][2] == 4, 'mark row ' .. tostring(ms[1] and ms[1][2]))
  assert(eol(ms[1]):find('⇒ 2', 1, true))
end)

test('scratch: stale types are dropped', function()
  local buf = mkbuf({ '> 1 + 1' }, 2)
  S.render(buf, params('types', 1, { W(1, { type = 'Int' }) }))
  assert(#marks(buf) == 0)
end)

test('scratch: multi-line value is capped', function()
  local buf = mkbuf({ '> xs' })
  local lines = {}
  for i = 1, 20 do lines[i] = 'line' .. i end
  S.render(buf, params('types', 1, { W(1, { type = 'String' }) }))
  S.render(buf, params('values', 1, { W(1, { type = 'String', value = table.concat(lines, '\n') }) }))
  local vl = marks(buf)[1][4].virt_lines
  assert(#vl == 8, #vl)
  assert(vl[8][1][1] == '… (12 more lines, <leader>ao to open)', vl[8][1][1])
  assert(vl[1][1][1] == 'line2')
end)

test('scratch: error and effect watches', function()
  local buf = mkbuf({ '> a', '> b', '> c' })
  S.render(buf, params('types', 1, { W(1, {}), W(2, { type = 'Int' }), W(3, { type = 'Query Int', value = '<query>', note = 'not run' }) }))
  S.render(buf, params('values', 1, {
    W(1, { error = 'boom' }), W(2, { type = 'Int', value = '1' }), W(3, { type = 'Query Int', value = '<query>', note = 'not run' }),
  }, { warning = 'unwired' }))
  local ms = marks(buf)
  local by = {}
  for _, m in ipairs(ms) do by[#by + 1] = m end
  local texts = {}
  for _, m in ipairs(by) do texts[#texts + 1] = m[2] .. ':' .. eol(m) end
  local all = table.concat(texts, '|')
  assert(all:find('✗ boom', 1, true), all)
  assert(all:find('<query> : Query Int  (not run)', 1, true), all)
  assert(all:find('unwired', 1, true), all)
  local hl
  for _, m in ipairs(by) do if eol(m):find('✗', 1, true) then hl = m[4].virt_text[1][2] end end
  assert(hl == 'AlderScratchError')
end)

test('scratch: edit dims values', function()
  local buf = mkbuf({ '> 1 + 1' })
  S.render(buf, params('types', 1, { W(1, { type = 'Int' }) }))
  S.render(buf, params('values', 1, { W(1, { type = 'Int', value = '2' }) }))
  assert(marks(buf)[1][4].virt_text[1][2] == 'AlderScratchValue')
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '> 1 + 2' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
  assert(marks(buf)[1][4].virt_text[1][2] == 'AlderScratchPending')
end)

test('scratch: open_value shows the whole value', function()
  local buf = mkbuf({ '> xs' })
  local lines = {}
  for i = 1, 20 do lines[i] = 'line' .. i end
  S.render(buf, params('types', 1, { W(1, { type = 'String' }) }))
  S.render(buf, params('values', 1, { W(1, { type = 'String', value = table.concat(lines, '\n') }) }))
  assert(S.value_at(buf, 1).type == 'String' and S.value_at(buf, 5) == nil)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  S.open_value()
  local t = H.float_text()
  assert(t:find('line20', 1, true) and t:find('line1\n', 1, true), t)
end)

test('scratch: end to end', function()
  local root = H.new_app()
  local base = vim.fs.dirname(root)
  vim.cmd.edit(root .. '/scratch.alder')
  local buf = vim.api.nvim_get_current_buf()
  assert(H.wait(10000, function() return vim.b[buf].alder_lsp end), 'not attached')
  vim.cmd.write()
  local ok = H.wait(180000, function()
    for _, m in ipairs(marks(buf)) do if eol(m):find('⇒ 2 : Int', 1, true) and m[2] == 4 then return true end end
  end)
  local got = {}
  for _, m in ipairs(marks(buf)) do got[#got + 1] = m[2] .. ':' .. eol(m) end
  for _, c in ipairs(vim.lsp.get_clients({ name = 'alder' })) do c:stop(true) end
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(base, 'rf')
  assert(ok, 'no value: ' .. table.concat(got, '|'))
end)

test('scratch: template matches the scaffold', function()
  local want = H.read(H.alder_repo() .. '/internal/scaffold/files/scratch.alder')
  assert(want, 'no scaffold file')
  assert(S.TEMPLATE == want, vim.inspect(S.TEMPLATE))
end)

local function scratch_app()
  local app = H.tmpdir()
  vim.fn.mkdir(app .. '/app', 'p')
  return app
end

local function cleanup(app)
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(app, 'rf')
end

test('scratch: open creates the file', function()
  local app = scratch_app()
  local ok, err = pcall(function()
    S.open(app)
    assert(H.read(app .. '/scratch.alder') == S.TEMPLATE, 'template not written')
    assert(vim.api.nvim_buf_get_name(0) == app .. '/scratch.alder')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'mine' })
    vim.cmd('silent write')
    S.open(app)
    assert(H.read(app .. '/scratch.alder') == 'mine\n', 'an existing file was overwritten')
  end)
  cleanup(app)
  assert(ok, err)
end)

test('scratch: append writes an indented watch and saves', function()
  local app = scratch_app()
  local ok, err = pcall(function()
    S.append(app, { '  a', '  b' }, nil)
    local text = H.read(app .. '/scratch.alder')
    assert(text == S.TEMPLATE .. '\n> a\n    b\n', vim.inspect(text))
    local buf = vim.fn.bufnr(app .. '/scratch.alder')
    assert(buf > 0 and not vim.bo[buf].modified, 'buffer left modified')
    local lines = vim.api.nvim_buf_get_lines(buf, -5, -1, false)
    assert(vim.deep_equal(lines, { '> 1 + 1', '', '> a', '    b' }), vim.inspect(lines))
  end)
  cleanup(app)
  assert(ok, err)
end)

test('scratch: send inside scratch.alder adds no second >', function()
  local app = scratch_app()
  local ok, err = pcall(function()
    H.write(app .. '/scratch.alder', '> 1 + 1\n> xs\n    |> f\n')
    vim.cmd.edit(app .. '/scratch.alder')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    S.send_current('n')
    vim.fn.setpos("'<", { 0, 2, 1, 0 })
    vim.fn.setpos("'>", { 0, 3, 1, 0 })
    S.send_current('x')
    local text = H.read(app .. '/scratch.alder')
    assert(text == '> 1 + 1\n> xs\n    |> f\n\n> 1 + 1\n\n> xs\n    |> f\n', vim.inspect(text))
  end)
  cleanup(app)
  assert(ok, err)
end)

test('scratch: append warns about the in header', function()
  local app = scratch_app()
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(function()
    S.reset_warned()
    S.append(app, { 'x' }, 'Todo')
    S.append(app, { 'y' }, 'Todo')
    local n = 0
    for _, m in ipairs(msgs) do
      if m.msg == 'alder: scratch.alder is not "in Todo"; names from Todo need qualifying (add "in Todo" as its first line)' then n = n + 1 end
    end
    assert(n == 1, vim.inspect(msgs))
  end)
  restore()
  cleanup(app)
  assert(ok, err)
end)

test('scratch: append does not warn when the in header matches or no module', function()
  local app = scratch_app()
  H.write(app .. '/scratch.alder', 'in Todo\n\n> 1\n')
  local msgs, restore = H.capture_notify()
  local ok, err = pcall(function()
    S.reset_warned()
    S.append(app, { 'x' }, 'Todo')
    S.append(app, { 'y' }, nil)
    assert(#msgs == 0, vim.inspect(msgs))
  end)
  restore()
  cleanup(app)
  assert(ok, err)
end)

test('scratch: a 9-line value is shown whole', function()
  local buf = mkbuf({ '> xs' })
  local lines = {}
  for i = 1, 9 do lines[i] = 'line' .. i end
  S.render(buf, params('types', 1, { W(1, { type = 'String' }) }))
  S.render(buf, params('values', 1, { W(1, { type = 'String', value = table.concat(lines, '\n') }) }))
  local vl = marks(buf)[1][4].virt_lines
  assert(#vl == 8 and vl[8][1][1] == 'line9', vim.inspect(vl))
end)

test('scratch: the handler ignores unknown uris and marks go on wipeout', function()
  local before = #vim.api.nvim_list_bufs()
  S.handler(nil, params('types', 1, { W(1, { type = 'Int' }) }, { uri = 'file:///nope/never.alder' }))
  assert(#vim.api.nvim_list_bufs() == before, 'a buffer was created')
  local buf = mkbuf({ '> 1' })
  S.render(buf, params('types', 1, { W(1, { type = 'Int' }) }))
  assert(S.marks[buf])
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(S.marks[buf] == nil)
end)

test('scratch: append runs end to end (save triggers the value)', function()
  local root = H.new_app()
  local base = vim.fs.dirname(root)
  S.append(root, { '2 + 3' }, nil)
  local buf = vim.fn.bufnr(root .. '/scratch.alder')
  local ok = buf > 0 and H.wait(180000, function()
    for _, m in ipairs(marks(buf)) do if eol(m):find('⇒ 5 : Int', 1, true) then return true end end
  end)
  local got = {}
  for _, m in ipairs(buf > 0 and marks(buf) or {}) do got[#got + 1] = m[2] .. ':' .. eol(m) end
  for _, c in ipairs(vim.lsp.get_clients({ name = 'alder' })) do c:stop(true) end
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(base, 'rf')
  assert(ok, 'no value: ' .. table.concat(got, '|'))
end)
