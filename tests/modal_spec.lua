local H = require('helpers')
local modal = require('alder.modal')

local function blog_buf(rel)
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  vim.cmd.edit(dst .. '/' .. rel)
  local buf = vim.api.nvim_get_current_buf()
  assert(H.wait(5000, function() return vim.b[buf].alder_lsp end), 'not attached')
  H.wait(1500, function() return false end) -- the first analysis
  return buf, dst
end

-- sized runs fn with the editor at cols x 40 and restores it, even when fn fails.
local function sized(cols, fn)
  local c, l = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = cols, 40
  local ok, err = pcall(fn)
  modal.close()
  vim.o.columns, vim.o.lines = c, l
  if not ok then error(err, 0) end
end

local function open(buf, opts)
  modal.open(buf, opts)
  assert(H.wait(5000, function() return modal.state ~= nil and modal.state.bufs ~= nil end), 'modal did not open')
  return modal.state
end

test('modal: opens with the panes titled, here group first, search focused', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    vim.fn.search('load params')
    local s = open(buf)
    local text = H.float_text()
    for _, t in ipairs({ ' Generate ', ' Preview ', 'new msg' }) do
      assert(text:find(t, 1, true), 'missing ' .. t .. ':\n' .. text)
    end
    -- the group headings are virtual lines above their rows, not buffer text
    local heads = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.bufs.list, -1, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do table.insert(heads, vl[1][1]) end
    end
    assert(vim.deep_equal(heads, { '── here ──', '── all ──' }), vim.inspect(heads))
    assert(#s.items >= 19 and s.items[1].here and s.filtered[1].id == s.items[1].id, vim.inspect(s.items[1]))
    assert(vim.api.nvim_get_current_win() == s.win.search)
    assert(text:find((' %d of %d '):format(#s.items, #s.items), 1, true), text)
  end)
end)

test('modal: Esc closes every float and restores the cursor; close is idempotent', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    vim.api.nvim_win_set_cursor(0, { 9, 3 })
    local win = vim.api.nvim_get_current_win()
    open(buf)
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
    assert(H.wait(2000, function() return modal.state == nil end), 'state kept')
    assert(H.float_text() == '', 'floats left:\n' .. H.float_text())
    assert(vim.api.nvim_get_current_win() == win)
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), { 9, 3 }), vim.inspect(vim.api.nvim_win_get_cursor(win)))
    modal.close()
    modal.close()
  end)
end)

test('modal: typing filters, arrows move, an empty list is harmless', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    local s = open(buf)
    modal.type_query('new msg')
    assert(s.filtered[1].id == 'new msg' and s.selected == 1, vim.inspect(s.filtered))
    assert(modal.selected().id == 'new msg')
    modal.type_query('')
    modal.move(1)
    assert(s.selected == 2 and modal.selected().id == s.items[2].id)
    modal.move(-5)
    assert(s.selected == 1)
    modal.type_query('zzzzzz')
    assert(#s.filtered == 0 and modal.selected() == nil)
    modal.move(1)
    modal.enter()
    assert(modal.state ~= nil, 'enter on an empty list closed the modal')
    assert(H.float_text():find(' 0 of ', 1, true), H.float_text())
    -- typing in the search buffer itself drives the same path
    vim.api.nvim_buf_set_lines(s.bufs.search, 0, -1, false, { 'page' })
    modal.on_search_changed()
    assert(s.query == 'page', s.query)
    assert(modal.selected().id:find('page', 1, true))
  end)
end)

test('modal: opening twice leaves one modal; leaving its windows closes it', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    local function floats()
      local n = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then n = n + 1 end
      end
      return n
    end
    open(buf)
    local first, one = modal.state, floats()
    open(buf)
    assert(modal.state ~= first)
    assert(floats() == one, 'two modals: ' .. floats() .. ' floats, one has ' .. one)
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(modal.state.origin.win) -- back to the editor window
    assert(H.wait(2000, function() return modal.state == nil end), 'leaving did not close')
    assert(H.float_text() == '')
  end)
end)

test('modal: narrow editors stack the panes', function()
  sized(80, function()
    local buf = blog_buf('app/Posts/Index.alder')
    local s = open(buf)
    local list, formw = vim.api.nvim_win_get_position(s.win.list), vim.api.nvim_win_get_position(s.win.form)
    assert(list[2] == formw[2] and list[1] < formw[1], vim.inspect({ list, formw }))
  end)
end)

test('modal: wide editors put the form beside the list', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    local s = open(buf)
    local list, formw = vim.api.nvim_win_get_position(s.win.list), vim.api.nvim_win_get_position(s.win.form)
    assert(list[2] < formw[2], vim.inspect({ list, formw }))
  end)
end)

test('modal: without nui, one notification and nothing opens', function()
  local buf = blog_buf('app/Posts/Index.alder')
  local saved = package.loaded['nui.popup']
  package.loaded['nui.popup'] = nil
  package.preload['nui.popup'] = function() error('not installed') end
  local messages, restore = H.capture_notify()
  modal.open(buf)
  restore()
  package.preload['nui.popup'] = nil
  package.loaded['nui.popup'] = saved
  assert(messages[1] and messages[1].msg == require('alder.ui').MISSING, vim.inspect(messages))
  assert(modal.state == nil)
end)
