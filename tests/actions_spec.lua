local H = require('helpers')

local function blog_buf(rel)
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  vim.cmd.edit(dst .. '/' .. rel)
  local buf = vim.api.nvim_get_current_buf()
  assert(H.wait(5000, function() return vim.b[buf].alder_lsp end), 'not attached')
  H.wait(1500, function() return false end)
  return buf, dst
end

local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end

-- stub_select answers every vim.ui.select with the first item whose title contains pick (nil when
-- none does); restore() puts the real one back.
local function stub_select(pick)
  local seen, orig = {}, vim.ui.select
  vim.ui.select = function(items, opts, cb)
    table.insert(seen, { items = items, opts = opts })
    local fmt = opts.format_item or tostring
    for _, it in ipairs(items) do
      if fmt(it):find(pick, 1, true) then return cb(it) end
    end
    cb(nil)
  end
  return seen, function() vim.ui.select = orig end
end

-- stub_input answers vim.ui.input with answer (nil cancels) and records each prompt.
local function stub_input(answer)
  local asked, orig = {}, vim.ui.input
  vim.ui.input = function(opts, cb) table.insert(asked, opts.prompt); cb(answer) end
  return asked, function() vim.ui.input = orig end
end

-- guarded runs f and always restores, so a failure never leaves a stub behind.
local function guarded(restores, f)
  local ok, err = pcall(f)
  for _, r in ipairs(restores) do pcall(r) end
  if not ok then error(err, 0) end
end

test('actions: a fix applies its edit', function()
  local buf = blog_buf('app/Posts/Index.alder')
  local l = vim.fn.search('^import Layout') - 1
  vim.api.nvim_buf_set_lines(buf, l, l + 1, false, {})
  local function fix_diag()
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if d.message:find('Layout', 1, true) then return d end
    end
  end
  assert(H.wait(5000, fix_diag), 'no diagnostic naming Layout: ' .. vim.inspect(vim.diagnostic.get(buf)))
  local d = fix_diag()
  vim.api.nvim_win_set_cursor(0, { d.lnum + 1, d.col })
  local seen, restore = stub_select('Fix: ')
  guarded({ restore }, function()
    require('alder.actions').open()
    assert(H.wait(3000, function() return #seen > 0 end), 'no menu')
  end)
  assert(seen[1].opts.format_item(seen[1].items[1]):find('^Fix: '), 'fixes come first')
  assert(H.wait(3000, function()
    return vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'import Layout')
  end), 'fix not applied')
end)

test('actions: a generator asks for the missing field, previews, applies in the user window', function()
  local buf = blog_buf('app/Posts/Index.alder')
  local user_win = vim.api.nvim_get_current_win()
  vim.fn.search('load params')
  local seen, restore = stub_select('new msg')
  local asked, restore_input = stub_input('Delete')
  guarded({ restore, restore_input }, function()
    require('alder.actions').open()
    assert(H.wait(10000, function() return vim.fn.bufexists('alder://preview') == 1 end), 'no preview')
  end)
  assert(asked[1] and asked[1]:find('^name'), vim.inspect(asked))
  local pv = vim.fn.bufnr('alder://preview')
  local lines = vim.api.nvim_buf_get_lines(pv, 0, -1, false)
  assert(lines[1] == '-- <CR> applies, q discards: new msg', lines[1])
  assert(table.concat(lines, '\n'):find('Delete', 1, true))
  vim.api.nvim_set_current_buf(pv)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  assert(H.wait(10000, function() return text(buf):find('Delete', 1, true) end), 'not applied')
  assert(vim.fn.bufexists('alder://preview') == 0, 'the preview is still open')
  assert(vim.api.nvim_win_get_buf(user_win) == buf, 'the user window lost the buffer')
  assert(vim.api.nvim_get_current_win() == user_win)
end)

test('actions: a cancelled input stops the flow silently', function()
  blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  local messages, restore_notify = H.capture_notify()
  local asked, restore_input = stub_input(nil)
  guarded({ restore_notify, restore_input }, function()
    require('alder.flow').open(0, 'new msg', {})
    assert(H.wait(5000, function() return #asked > 0 end), 'no prompt')
    H.wait(500, function() return false end)
  end)
  assert(#messages == 0, vim.inspect(messages))
  assert(vim.fn.bufexists('alder://preview') == 0)
end)

test('actions: the alder.generate client command opens the same flow', function()
  local buf = blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  local asked, restore = stub_input('Delete')
  guarded({ restore }, function()
    vim.lsp.commands['alder.generate']({ command = 'alder.generate', arguments = { { id = 'new msg', sets = {} } } },
      { bufnr = buf })
    assert(H.wait(10000, function() return vim.fn.bufexists('alder://preview') == 1 end), 'no preview')
  end)
  assert(asked[1] and asked[1]:find('^name'), vim.inspect(asked))
end)

test('actions: nothing here points to the first line with something', function()
  local buf = blog_buf('app/Posts/Index.alder')
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- the blank line after `module`
  local messages, restore = H.capture_notify()
  local seen, restore_sel = stub_select('nothing will match')
  guarded({ restore, restore_sel }, function()
    require('alder.actions').open()
    H.wait(3000, function() return #messages > 0 or #seen > 0 end)
  end)
  -- a page module offers here generators on every line, so either a menu or the message
  assert(#seen > 0 or (messages[1] and messages[1].msg:find('^alder: nothing applies here; the first line that has something is ')),
    vim.inspect(messages))
end)

test('actions: with no action at the cursor the message names a line or none', function()
  local buf = blog_buf('app/Markdown.alder')
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'module Markdown x = ' })
  H.wait(1000, function() return false end) -- the server reanalyses: lines above line 2 changed
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local messages, restore = H.capture_notify()
  local seen, restore_sel = stub_select('nothing will match')
  guarded({ restore, restore_sel }, function()
    require('alder.actions').open()
    H.wait(3000, function() return #messages > 0 end)
  end)
  assert(#seen == 0, 'a menu was shown: ' .. vim.inspect(seen[1] and seen[1].items))
  local m = messages[1] and messages[1].msg
  assert(m and (m:match('^alder: nothing applies here; the first line that has something is (%d+)$')
    or m == 'alder: nothing applies here; the first line that has something is none'), vim.inspect(messages))
end)

test('generate: :AlderGenerate lists every generator, here first', function()
  blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  local seen, restore = stub_select('nothing will match')
  guarded({ restore }, function()
    vim.cmd('AlderGenerate')
    assert(H.wait(3000, function() return #seen > 0 end), 'no menu')
  end)
  assert(#seen[1].items == 19, #seen[1].items)
  local first = seen[1].opts.format_item(seen[1].items[1])
  assert(first:find('  (here: ', 1, true), first)
  assert(not seen[1].opts.format_item(seen[1].items[19]):find('here', 1, true))
end)

test('generate: :AlderGenerate <id> goes straight to the flow; ids complete', function()
  blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  local asked, restore = stub_input(nil)
  guarded({ restore }, function()
    vim.cmd('AlderGenerate new msg')
    assert(H.wait(5000, function() return #asked > 0 end), 'no prompt')
  end)
  local ids = vim.fn.getcompletion('AlderGenerate new m', 'cmdline')
  assert(vim.tbl_contains(ids, 'msg'), vim.inspect(ids)) -- the last word, as the command line completes it
end)
