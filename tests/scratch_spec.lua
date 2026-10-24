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
