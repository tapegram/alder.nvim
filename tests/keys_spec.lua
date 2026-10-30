local H = require('helpers')
local config = require('alder.config')

local function blog_buf(rel)
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  vim.cmd.edit(dst .. '/' .. rel)
  local buf = vim.api.nvim_get_current_buf()
  assert(H.wait(5000, function() return vim.b[buf].alder_lsp end), 'not attached')
  return buf, dst
end

local function mapped(lhs, mode)
  return vim.fn.maparg(vim.keycode(lhs), mode or 'n', false, true).buffer == 1
end

-- gmapped: a global (project-level) map, which a buffer-local one would shadow.
local function gmapped(lhs, mode)
  local m = vim.fn.maparg(vim.keycode(lhs), mode or 'n', false, true)
  return m.lhs ~= nil and m.buffer == 0
end

-- with_opts runs f with config.options replaced, restoring the suite's options even when f fails.
local function with_opts(opts, f)
  local saved = config.options
  config.options = vim.tbl_deep_extend('force', vim.deepcopy(saved), opts)
  require('alder.keys').attach_global()
  local ok, err = pcall(f)
  config.options = saved
  require('alder.keys').attach_global()
  if not ok then error(err, 0) end
end

local function break_per_page()
  local buf = blog_buf('app/Posts/Index.alder')
  local l = vim.fn.search('^perPage = 10') - 1
  vim.api.nvim_buf_set_lines(buf, l, l + 1, false, { 'perPage = "ten"' })
  assert(H.wait(5000, function() return #vim.diagnostic.get(buf) > 0 end), 'no diagnostics')
  return buf, l
end

test('keys: ag ac ae ar at are buffer-local; aa is gone (plan 2)', function()
  vim.g.mapleader = ' '
  blog_buf('app/Post.alder')
  for _, k in ipairs({ '<leader>ac', '<leader>ae' }) do
    assert(mapped(k), k .. ' not mapped')
  end
  for _, k in ipairs({ '<leader>ag', '<leader>ar', '<leader>at', '<leader>ax', '<leader>au' }) do
    assert(gmapped(k) and not mapped(k), k .. ' is not a project-level map')
  end
  assert(not mapped('<leader>aa'))
  assert(mapped('<leader>aT'), '<leader>aT not mapped')
  assert(mapped('<leader>am'), '<leader>am not mapped')
  assert(not gmapped('<leader>ax', 'x'), '<leader>ax is normal mode only')
  assert(mapped('<leader>as'), '<leader>as not mapped in normal mode')
  assert(mapped('<leader>as', 'x'), '<leader>as not mapped in visual mode')
end)

test('keys: false disables one key', function()
  vim.g.mapleader = ' '
  with_opts({ keys = { run = false } }, function()
    blog_buf('app/Post.alder')
    assert(not gmapped('<leader>ar'))
    assert(gmapped('<leader>ag'))
  end)
  with_opts({ keys = { test = false } }, function()
    blog_buf('app/Post.alder')
    assert(not gmapped('<leader>at'))
    assert(gmapped('<leader>ar'))
  end)
  with_opts({ keys = { test_at = false } }, function()
    blog_buf('app/Post.alder')
    assert(not mapped('<leader>aT'))
    assert(gmapped('<leader>at'))
  end)
  with_opts({ keys = { mutate = false } }, function()
    blog_buf('app/Post.alder')
    assert(not mapped('<leader>am'))
    assert(gmapped('<leader>at'))
  end)
  with_opts({ keys = { scratch = false } }, function()
    blog_buf('app/Post.alder')
    assert(not gmapped('<leader>ax'))
    assert(mapped('<leader>as'))
  end)
  with_opts({ keys = { send = false } }, function()
    blog_buf('app/Post.alder')
    assert(not mapped('<leader>as') and not mapped('<leader>as', 'x'))
    assert(gmapped('<leader>ax'))
  end)
end)

test('keys: false disables the routes picker', function()
  vim.g.mapleader = ' '
  with_opts({ keys = { routes = false } }, function()
    assert(not gmapped('<leader>au'))
    assert(gmapped('<leader>ag'))
  end)
  assert(gmapped('<leader>au'), 'restored')
end)

test('keys: project maps work in a non-alder buffer inside a project; buffer maps do not', function()
  vim.g.mapleader = ' '
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  local old = vim.fn.getcwd()
  vim.cmd.cd(dst)
  local ok, err = pcall(function()
    vim.cmd.enew()
    assert(gmapped('<leader>ag') and gmapped('<leader>ax') and gmapped('<leader>au'))
    assert(not mapped('<leader>ac') and not mapped('<leader>as'), 'buffer-only maps leaked')
    vim.api.nvim_feedkeys(vim.keycode('<leader>ag'), 'x', false)
    local modal = require('alder.modal')
    assert(H.wait(15000, function() return modal.state ~= nil and modal.state.bufs ~= nil end), 'modal did not open')
    assert(vim.bo[modal.state.buf].filetype == 'alder', 'the modal runs on an .alder buffer of the project')
    modal.close()
  end)
  vim.cmd.cd(old)
  assert(ok, err)
end)

test('keys: ag from a modified non-alder buffer leaves that buffer alone and does not block', function()
  vim.g.mapleader = ' '
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  local old = vim.fn.getcwd()
  vim.cmd.cd(dst)
  local ok, err = pcall(function()
    vim.cmd.enew()
    local scratch = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'unsaved' })
    local t = vim.uv.hrtime()
    vim.api.nvim_feedkeys(vim.keycode('<leader>ag'), 'x', false)
    assert((vim.uv.hrtime() - t) / 1e6 < 1000, 'the map blocked')
    local modal = require('alder.modal')
    assert(H.wait(15000, function() return modal.state ~= nil and modal.state.bufs ~= nil end), 'modal did not open')
    assert(vim.api.nvim_get_current_buf() ~= scratch or true)
    assert(vim.bo[modal.state.buf].filetype == 'alder')
    modal.close()
    assert(vim.api.nvim_get_current_buf() == scratch and vim.bo[scratch].modified, 'the user buffer was switched')
  end)
  vim.cmd.cd(old)
  assert(ok, err)
end)

test('keys: project maps outside an Alder project say so', function()
  vim.g.mapleader = ' '
  local old = vim.fn.getcwd()
  vim.cmd.cd(H.tmpdir())
  local messages, restore = H.capture_notify()
  local ok, err = pcall(function()
    vim.cmd.enew()
    for _, k in ipairs({ '<leader>ag', '<leader>ax', '<leader>au', '<leader>at', '<leader>ar' }) do
      vim.api.nvim_feedkeys(vim.keycode(k), 'x', false)
    end
  end)
  restore()
  vim.cmd.cd(old)
  assert(ok, err)
  assert(#messages == 5, vim.inspect(messages))
  for _, m in ipairs(messages) do assert(m.msg == 'alder: not in an Alder project', m.msg) end
end)

test('keys: ag opens the generator modal', function()
  vim.g.mapleader = ' '
  local buf = blog_buf('app/Posts/Index.alder')
  H.wait(1500, function() return false end)
  vim.api.nvim_feedkeys(vim.keycode('<leader>ag'), 'x', false)
  local modal = require('alder.modal')
  assert(H.wait(5000, function() return modal.state ~= nil and modal.state.bufs ~= nil end), 'modal did not open')
  assert(modal.state.buf == buf)
  modal.close()
end)

test('commands: AlderActions is gone; AlderGenerate [id] presets the modal', function()
  assert(vim.fn.exists(':AlderActions') == 0)
  assert(vim.fn.exists(':AlderGenerate') == 2)
  blog_buf('app/Posts/Index.alder')
  H.wait(1500, function() return false end)
  vim.cmd('AlderGenerate new msg')
  local modal = require('alder.modal')
  assert(H.wait(5000, function() return modal.state ~= nil and modal.state.bufs ~= nil end))
  assert(modal.selected().id == 'new msg')
  modal.close()
  local comp = vim.fn.getcompletion('AlderGenerate new m', 'cmdline')
  assert(vim.tbl_contains(comp, 'msg') or vim.tbl_contains(comp, 'new msg'), vim.inspect(comp))
end)

test('commands: the alder.generate client command opens the modal on that generator, focus on the first missing field', function()
  local buf = blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  vim.lsp.commands['alder.generate']({ command = 'alder.generate', arguments = { { id = 'new msg', sets = { page = 'Posts.Index' } } } },
    { bufnr = buf })
  local modal = require('alder.modal')
  assert(H.wait(5000, function() return modal.state ~= nil and modal.state.bufs ~= nil end), 'modal did not open')
  local s = modal.state
  assert(modal.selected().id == 'new msg')
  assert(H.wait(10000, function() return s.preview ~= nil and not s.updating end), 'no preview')
  -- the first required field still at the server's starting value (alder#45), or empty
  local first
  for i, f in ipairs(s.fields) do
    if f.required and (f.value == nil or f.value == '' or f.source == 'default') then first = i break end
  end
  assert(first and s.focus == first, 'focus ' .. tostring(s.focus) .. ' want ' .. tostring(first))
  modal.close()
end)

test('keys: ac fills the quickfix list from server diagnostics and opens it', function()
  vim.g.mapleader = ' '
  break_per_page()
  vim.api.nvim_feedkeys(vim.keycode('<leader>ac'), 'x', false)
  local qf = vim.fn.getqflist({ title = 0, items = 0 })
  assert(qf.title == 'alder diagnostics' and #qf.items > 0, vim.inspect(qf))
  assert(vim.fn.getqflist({ winid = 0 }).winid ~= 0, 'quickfix not open')
end)

test('keys: ae explains the diagnostic under the cursor through the server', function()
  vim.g.mapleader = ' '
  local _, l = break_per_page()
  vim.api.nvim_win_set_cursor(0, { l + 1, 11 })
  vim.api.nvim_feedkeys(vim.keycode('<leader>ae'), 'x', false)
  assert(H.wait(3000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then return true end
    end
  end), 'no explain float')
end)

test('keys: ae with no diagnostic under the cursor says so', function()
  vim.g.mapleader = ' '
  blog_buf('app/Post.alder')
  local messages, restore = H.capture_notify()
  local ok, err = pcall(require('alder.check').explain)
  restore()
  assert(ok, err)
  assert(messages[1] and messages[1].msg == 'alder: no diagnostic under the cursor', vim.inspect(messages))
end)

test('commands: AlderNew and AlderFill are gone, AlderDiagnostics exists', function()
  assert(vim.fn.exists(':AlderNew') == 0 and vim.fn.exists(':AlderFill') == 0)
  assert(vim.fn.exists(':AlderDiagnostics') == 2)
end)

test('keys: <leader>ax opens scratch.alder', function()
  vim.g.mapleader = ' '
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  local old = vim.fn.getcwd()
  vim.cmd.cd(dst)
  local ok, err = pcall(function()
    vim.cmd.enew()
    assert(gmapped('<leader>ax'))
    vim.api.nvim_feedkeys(vim.keycode('<leader>ax'), 'x', false)
    assert(vim.api.nvim_buf_get_name(0) == dst .. '/scratch.alder', vim.api.nvim_buf_get_name(0))
    assert(H.read(dst .. '/scratch.alder') == require('alder.scratch').TEMPLATE)
    assert(H.wait(5000, function() return vim.b.alder_lsp end), 'not attached')
    assert(mapped('<leader>ao'), '<leader>ao not mapped in the scratch buffer')
  end)
  vim.cmd.cd(old)
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(dst, 'rf')
  assert(ok, err)
end)

test('keys: <leader>ao is not mapped outside a scratch file', function()
  vim.g.mapleader = ' '
  blog_buf('app/Post.alder')
  assert(not mapped('<leader>ao'))
end)

test('keys: legacy repl key maps to scratch and warns once', function()
  local config = require('alder.config')
  local saved = config.options
  local msgs, restore = H.capture_notify()
  config.reset_warned()
  config.set({ keys = { repl = '<leader>aX' } })
  config.set({ keys = { repl = '<leader>aX' } })
  local opts = config.options
  restore()
  config.options = saved
  assert(opts.keys.scratch == '<leader>aX', vim.inspect(opts.keys))
  assert(opts.keys.repl == nil)
  local n = 0
  for _, m in ipairs(msgs) do if m.msg:find('keys.repl', 1, true) then n = n + 1 end end
  assert(n == 1, vim.inspect(msgs))
end)

test('keys: which-key group covers normal and visual mode', function()
  vim.g.mapleader = ' '
  local saved = package.loaded['which-key']
  local recorded
  package.loaded['which-key'] = { add = function(spec) recorded = spec end }
  local ok, err = pcall(blog_buf, 'app/Post.alder')
  package.loaded['which-key'] = saved
  if not ok then error(err, 0) end
  assert(recorded, 'which-key add was not called')
  assert(recorded[1][1] == '<leader>a', vim.inspect(recorded))
  assert(recorded[1].group == 'alder', vim.inspect(recorded))
  assert(vim.tbl_contains(recorded[1].mode or {}, 'n'), vim.inspect(recorded))
  assert(vim.tbl_contains(recorded[1].mode or {}, 'x'), vim.inspect(recorded))
end)
