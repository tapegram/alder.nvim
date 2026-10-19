local ui = require('alder.ui')

test('ui: plain strips vim.NIL at any depth', function()
  local got = ui.plain({ a = vim.NIL, b = { c = vim.NIL, d = 1 }, e = 'x' })
  assert(got.a == nil and got.b.c == nil and got.b.d == 1 and got.e == 'x', vim.inspect(got))
  assert(ui.plain(vim.NIL) == nil)
  assert(ui.plain(3) == 3)
end)

test('ui: has_nui is true here, false when nui cannot load', function()
  assert(ui.has_nui(), 'nui.nvim not on the runtimepath (NVIM_NUI)')
  local saved = package.loaded['nui.popup']
  package.loaded['nui.popup'] = nil
  package.preload['nui.popup'] = function() error('not installed') end
  local ok = ui.has_nui()
  package.preload['nui.popup'] = nil
  package.loaded['nui.popup'] = saved
  assert(not ok, 'has_nui ignored the failing require')
end)

test('ui: pane is a rounded popup titled top-left', function()
  local p = ui.pane('Generate', { enter = true, relative = 'editor', position = '50%', size = { width = 40, height = 3 } })
  p:mount()
  local text = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      vim.list_extend(text, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false))
    end
  end
  p:unmount()
  assert(table.concat(text, '\n'):find(' Generate ', 1, true), vim.inspect(text))
end)

test('ui: narrow below 100 columns', function()
  local cols = vim.o.columns
  vim.o.columns = 80
  assert(ui.narrow())
  vim.o.columns = 140
  assert(not ui.narrow())
  vim.o.columns = cols
end)
