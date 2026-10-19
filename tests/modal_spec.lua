local H = require('helpers')
local modal = require('alder.modal')
local form = require('alder.form')

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
    -- the `here` heading is drawn only when the list window shows one filler line above row 1
    local topfill = vim.api.nvim_win_call(s.win.list, function() return vim.fn.winsaveview().topfill end)
    assert(topfill == 1, 'the here heading is not shown: topfill = ' .. tostring(topfill))
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
    assert(#s.fields == 0 and not s.ready and not s.updating, 'the form was not cleared on an empty list')
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(s.bufs.form, 0, -1, false), { '' }))
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

local function form_options(f, s) return form.options(f, s.typed[f.name]) end

local function text_of(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end

local function wait_preview(s)
  assert(H.wait(10000, function() return s.preview ~= nil and not s.updating end), 'no preview answer')
end

-- opened_msg opens the modal on `new msg` at Posts/Index's `load params` and waits for the first preview.
local function opened_msg(id)
  local buf = blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  local s = open(buf)
  modal.type_query(id or 'new msg')
  wait_preview(s)
  return buf, s
end

test('modal: selecting a generator shows its form; typing a field updates the preview', function()
  sized(140, function()
    local _, s = opened_msg()
    local names = vim.tbl_map(function(f) return f.name end, s.fields)
    assert(names[1] == 'page' and names[2] == 'name' and #names == 6, vim.inspect(names))
    local lines = vim.api.nvim_buf_get_lines(s.bufs.form, 0, -1, false)
    assert(lines[1] == 'Posts.Index' and lines[2] == '', vim.inspect(lines))
    assert(not s.ready)
    assert(H.float_text():find(' new msg  ', 1, true), 'form title lacks the id:\n' .. H.float_text())
    modal.set_field('name', 'Delete')
    assert(not s.ready, 'ready must drop while the preview is in flight')
    assert(H.wait(10000, function() return s.ready end), 'never ready: ' .. vim.inspect(s.preview))
    local pv = text_of(s.bufs.preview)
    assert(pv:find('~ app/Posts/Index.alder  +', 1, true) and pv:find('@@', 1, true) and pv:find('Delete', 1, true), pv)
    assert(H.float_text():find(' app/Posts/Index.alder ', 1, true), 'preview title is the main file')
  end)
end)

test('modal: Tab moves search -> fields -> search; the cursor row focuses a field', function()
  sized(140, function()
    local _, s = opened_msg()
    modal.focus_next()
    assert(vim.api.nvim_get_current_win() == s.win.form and s.focus == 1, vim.inspect(s.focus))
    modal.focus_next()
    assert(s.focus == 2)
    for _ = 3, #s.fields do modal.focus_next() end
    assert(s.focus == #s.fields)
    modal.focus_next()
    assert(s.focus == nil and vim.api.nvim_get_current_win() == s.win.search, 'did not wrap to search')
    modal.focus_prev()
    assert(s.focus == #s.fields)
    modal.focus_search()
    vim.api.nvim_feedkeys(vim.keycode('<S-Tab>'), 'x', false)
    assert(s.focus == #s.fields, 'S-Tab on the search line did not reach the last field')
    -- the cursor on another row focuses that field
    vim.api.nvim_win_set_cursor(s.win.form, { 2, 0 })
    modal.on_cursor_moved()
    assert(s.focus == 2)
    assert(s.typed.page == nil, 'moving past a field wrote it')
  end)
end)

test('modal: typing in the form buffer is a field edit; a joined line is put back', function()
  sized(140, function()
    local _, s = opened_msg()
    modal.focus_field(2)
    vim.api.nvim_feedkeys('AToggle', 'x', false)
    modal.on_form_changed()
    assert(s.typed.name == 'Toggle', vim.inspect(s.typed))
    assert(H.wait(10000, function() return s.ready end))
    vim.api.nvim_buf_set_lines(s.bufs.form, 0, -1, false, { 'Posts.IndexToggle' }) -- a join
    modal.on_form_changed()
    assert(#vim.api.nvim_buf_get_lines(s.bufs.form, 0, -1, false) == #s.fields, 'rows not restored')
    assert(vim.api.nvim_buf_get_lines(s.bufs.form, 1, 2, false)[1] == 'Toggle', 'value lost in the re-render')
  end)
end)

test('modal: a choice field lists options; Down picks, Tab commits; passing over it commits nothing', function()
  sized(140, function()
    local _, s = opened_msg('remove page')
    modal.focus_field(1)
    local f = s.fields[1]
    assert(f.choices and #f.choices >= 2, vim.inspect(f))
    local has_options = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.bufs.form, -1, 0, -1, { details = true })) do
      if m[4].virt_lines then has_options = true end
    end
    assert(has_options, 'no options under the choice field')
    -- an unmoved pick commits nothing, even when it is not the first option
    modal.commit_option()
    assert(s.typed[f.name] == nil, vim.inspect(s.typed))
    local start = s.pick
    assert(modal.option(1))
    assert(s.pick == start % #form_options(f, s) + 1, 'pick ' .. s.pick)
    modal.commit_option()
    assert(s.typed[f.name] == form_options(f, s)[s.pick], vim.inspect(s.typed))
  end)
end)

test('modal: Enter when not ready jumps to the first invalid field; when ready it applies', function()
  sized(140, function()
    local buf, s = opened_msg()
    local before = text_of(buf)
    modal.enter()
    assert(modal.state == s and s.focus == 2 and vim.api.nvim_get_current_win() == s.win.form, 'enter did not jump to `name`')
    modal.set_field('name', 'Delete')
    -- a preview is in flight: enter must not apply the sets it has not previewed
    modal.enter()
    assert(modal.state == s and text_of(buf) == before, 'enter applied during an update')
    assert(H.wait(10000, function() return s.ready end))
    local messages, restore = H.capture_notify()
    modal.enter()
    assert(H.wait(10000, function() return text_of(buf):find('Delete', 1, true) ~= nil end), 'not applied: ' .. vim.inspect(messages))
    restore()
    assert(modal.state == nil and H.float_text() == '', 'modal still open after apply')
    assert(vim.api.nvim_get_current_buf() == buf)
    vim.cmd('silent undo')
    assert(text_of(buf) == before, 'one u does not restore')
  end)
end)

test('modal: an answer for sets changed since cannot mark the form ready', function()
  sized(140, function()
    local _, s = opened_msg()
    modal.set_field('name', 'Delete')
    local stale = s.seq
    modal.set_field('name', 'Other')
    assert(not s.ready and s.seq > stale)
    modal.on_preview(stale, { ready = true, fields = s.fields, files = {} })
    assert(not s.ready, 'a stale answer marked the form ready')
    modal.select(2) -- a selection change drops the in-flight answer too
    assert(not s.ready and s.seq > stale)
  end)
end)

test('modal: a preset selects the generator and focuses the first missing field', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    vim.fn.search('load params')
    local s = open(buf, { generator = 'new msg', sets = { page = 'Posts.Index' } })
    assert(modal.selected().id == 'new msg')
    assert(H.wait(10000, function() return s.focus == 2 end), 'focus ' .. tostring(s.focus))
    assert(vim.api.nvim_get_current_win() == s.win.form)
  end)
end)

test('modal: C-o opens the review over the modal; q returns to it; Enter applies', function()
  sized(140, function()
    local buf, s = opened_msg()
    modal.set_field('name', 'Delete')
    assert(H.wait(10000, function() return s.ready end))
    modal.review()
    assert(H.wait(10000, function() return H.float_text():find(' files ', 1, true) ~= nil end), H.float_text())
    assert(H.float_text():find('@@', 1, true) and s.suspended)
    vim.api.nvim_feedkeys('q', 'x', false)
    assert(H.wait(1000, function() return not s.suspended end))
    assert(modal.state == s and H.float_text():find(' Generate ', 1, true) and not H.float_text():find(' files ', 1, true))
    modal.review()
    assert(H.wait(10000, function() return H.float_text():find(' files ', 1, true) ~= nil end))
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    assert(H.wait(10000, function() return text_of(buf):find('Delete', 1, true) ~= nil end), 'review Enter did not apply')
    assert(modal.state == nil and H.float_text() == '')
  end)
end)

test('modal: a failed preview request clears updating and shows the error in the pane', function()
  sized(140, function()
    local _, s = opened_msg()
    local lsp = require('alder.lsp')
    local orig = lsp.request
    lsp.request = function(_, method, _, _, on_err)
      if method == 'alder/preview' and on_err then on_err({ code = -32603, message = 'boom' }) end
    end
    local messages, restore = H.capture_notify()
    local ok, err = pcall(function()
      modal.set_field('name', 'Delete')
      assert(H.wait(2000, function() return not s.updating end), 'updating stuck')
    end)
    restore()
    lsp.request = orig
    assert(ok, err)
    assert(modal.state == s and not s.ready and text_of(s.bufs.preview):find('boom', 1, true), text_of(s.bufs.preview))
  end)
end)

test('modal: an error with no server attached closes the modal and leaves no float', function()
  sized(140, function()
    local _, s = opened_msg()
    local lsp = require('alder.lsp')
    local orig, orig_client = lsp.request, lsp.client
    lsp.client = function() return nil end
    lsp.request = function(_, _, _, _, on_err) if on_err then on_err({ message = 'not attached' }) end end
    local ok, err = pcall(function()
      modal.set_field('name', 'Delete')
      assert(H.wait(2000, function() return modal.state == nil end), 'modal kept')
    end)
    lsp.request, lsp.client = orig, orig_client
    assert(ok, err)
    assert(H.float_text() == '', 'floats left:\n' .. H.float_text())
  end)
end)

test('modal: a closed modal\'s preview answer cannot paint into a reopened one', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    vim.fn.search('load params')
    local a = open(buf)
    local n = a.seq
    modal.close()
    local b = open(buf)
    modal.type_query('new msg')
    wait_preview(b)
    modal.set_field('name', 'Delete')
    assert(not b.ready)
    modal.on_preview(n, { ready = true, fields = {}, files = {} })
    assert(not b.ready and #b.fields > 0, 'an old modal\'s answer painted')
  end)
end)

test('modal: a plan that returns after the sets changed is not shown', function()
  sized(140, function()
    local _, s = opened_msg()
    modal.set_field('name', 'Delete')
    assert(H.wait(10000, function() return s.ready end))
    local lsp = require('alder.lsp')
    local orig, plan_cb = lsp.request, nil
    lsp.request = function(b, method, p, cb, on_err)
      if method == 'alder/plan' then plan_cb = cb else return orig(b, method, p, cb, on_err) end
    end
    local ok, err = pcall(function()
      modal.review()
      assert(plan_cb, 'no plan request')
      modal.set_field('name', 'Other')
      plan_cb({ files = {}, notes = {}, canApply = true })
      assert(not s.suspended and not H.float_text():find(' files ', 1, true), 'a stale plan was shown')
    end)
    lsp.request = orig
    assert(ok, err)
  end)
end)

test('modal: a bool flag renders as a switch; Space toggles it into the sets', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    local s = open(buf)
    modal.type_query('new page')
    wait_preview(s)
    local function find()
      for i, f in ipairs(s.fields) do
        if f.name == 'example' then return i, f end
      end
    end
    local function line(row) return vim.api.nvim_buf_get_lines(s.bufs.form, row - 1, row, false)[1] end
    local row = find()
    assert(row, 'new page has no `example` flag: build alder from the m6b-plan2 branch (go install ./cmd/alder)')
    assert(line(row) == '[x] example', vim.inspect(vim.api.nvim_buf_get_lines(s.bufs.form, 0, -1, false)))
    assert(form.sets(s.preset, s.typed).example == nil, 'a default must not be sent')
    modal.focus_field(row)
    vim.api.nvim_feedkeys(' ', 'x', false)
    assert(H.wait(1000, function() return s.typed.example == 'false' end), vim.inspect(s.typed))
    assert(line(row) == '[ ] example')
    assert(H.wait(10000, function() return s.preview ~= nil and not s.updating end))
    assert(form.sets(s.preset, s.typed).example == 'false')

    -- the server drops the default once `list` is set (DefaultUnless), and sets never carry it
    s.typed = {}
    modal.set_field('list', 'Post')
    assert(H.wait(10000, function() return s.preview ~= nil and not s.updating end))
    local r, f = find()
    assert(r and line(r) == '[ ] example', vim.inspect(vim.api.nvim_buf_get_lines(s.bufs.form, 0, -1, false)))
    assert(f.value == '' and f.source ~= 'default', vim.inspect(f))
    assert(form.sets(s.preset, s.typed).example == nil)
  end)
end)

test('modal: arrowing onto a switch row leaves insert mode so Space toggles', function()
  sized(140, function()
    local buf = blog_buf('app/Posts/Index.alder')
    local s = open(buf)
    modal.type_query('new page')
    wait_preview(s)
    local brow
    for i, f in ipairs(s.fields) do
      if f.kind == 'bool' then brow = i break end
    end
    assert(brow and brow > 1, 'new page needs a text field above a switch')
    -- the headless loop never applies :startinsert, so watch for the :stopinsert instead
    modal.focus_field(brow - 1)
    local stops, orig = 0, vim.cmd.stopinsert
    vim.cmd.stopinsert = function(...) stops = stops + 1 return orig(...) end
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(s.win.form, { brow - 1, 0 })
      modal.on_cursor_moved()
      assert(stops == 0, 'left insert for a text field')
      vim.api.nvim_win_set_cursor(s.win.form, { brow, 0 })
      modal.on_cursor_moved()
      assert(stops == 1, 'did not leave insert on the switch row: ' .. stops)
    end)
    vim.cmd.stopinsert = nil
    assert(ok, err)
  end)
end)

test('modal: a request the closing server refuses clears updating and says why', function()
  sized(140, function()
    local _, s = opened_msg()
    local c = require('alder.lsp').client(s.buf)
    local orig = c.request
    c.request = function() return false end
    local ok, err = pcall(function()
      modal.set_field('name', 'Delete')
      assert(H.wait(2000, function() return not s.updating end), 'updating stuck')
    end)
    c.request = orig
    assert(ok, err)
    assert(text_of(s.bufs.preview):find('alder lsp stopped', 1, true), text_of(s.bufs.preview))
  end)
end)
