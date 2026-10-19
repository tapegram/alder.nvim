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

local function mapped(lhs)
  return vim.fn.maparg(vim.keycode(lhs), 'n', false, true).buffer == 1
end

-- with_opts runs f with config.options replaced, restoring the suite's options even when f fails.
local function with_opts(opts, f)
  local saved = config.options
  config.options = vim.tbl_deep_extend('force', vim.deepcopy(saved), opts)
  local ok, err = pcall(f)
  config.options = saved
  if not ok then error(err, 0) end
end

local function break_per_page()
  local buf = blog_buf('app/Posts/Index.alder')
  local l = vim.fn.search('^perPage = 10') - 1
  vim.api.nvim_buf_set_lines(buf, l, l + 1, false, { 'perPage = "ten"' })
  assert(H.wait(5000, function() return #vim.diagnostic.get(buf) > 0 end), 'no diagnostics')
  return buf, l
end

test('keys: ag ac ae ar are buffer-local; aa is gone (plan 2)', function()
  vim.g.mapleader = ' '
  blog_buf('app/Post.alder')
  for _, k in ipairs({ '<leader>ag', '<leader>ac', '<leader>ae', '<leader>ar' }) do
    assert(mapped(k), k .. ' not mapped')
  end
  assert(not mapped('<leader>aa'))
end)

test('keys: false disables one key', function()
  vim.g.mapleader = ' '
  with_opts({ keys = { run = false } }, function()
    blog_buf('app/Post.alder')
    assert(not mapped('<leader>ar'))
    assert(mapped('<leader>ag'))
  end)
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
  local first
  for i, f in ipairs(s.fields) do
    if f.required and (f.value == nil or f.value == '') then first = i break end
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
