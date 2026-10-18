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
  local n = 0
  for _, m in ipairs(messages) do if m.msg == 'alder lsp stopped — :checkhealth alder' then n = n + 1 end end
  assert(n == 1, vim.inspect(messages))
end)
