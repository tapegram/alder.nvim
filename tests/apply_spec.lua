local H = require('helpers')
local apply = require('alder.apply')

-- blog_buf opens rel in a copy of examples/blog (after prep(root), if given) once the server is
-- attached and has analysed it.
local function blog_buf(rel, prep)
  local dst = H.tmpdir() .. '/blog'
  H.copy_tree(H.alder_repo() .. '/examples/blog', dst)
  if prep then prep(dst) end
  vim.cmd.edit(dst .. '/' .. rel)
  local buf = vim.api.nvim_get_current_buf()
  assert(H.wait(5000, function() return vim.b[buf].alder_lsp end), 'not attached')
  H.wait(1500, function() return false end)
  return buf, dst
end

local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end

test('apply: new msg edits the buffer, nothing on disk, one undo', function()
  local buf, root = blog_buf('app/Posts/Index.alder')
  local before = text(buf)
  vim.fn.search('load params')
  local done = false
  local messages, restore = H.capture_notify()
  apply.run(buf, 'new msg', { name = 'Delete' }, function() done = true end)
  H.wait(10000, function() return done end)
  restore()
  assert(done, 'not applied: ' .. vim.inspect(messages))
  assert(messages[1].msg == 'alder: applied new msg: app/Posts/Index.alder', vim.inspect(messages))
  assert(text(buf):find('Delete', 1, true), 'buffer not edited')
  assert(vim.bo[buf].modified)
  assert(not H.read(root .. '/app/Posts/Index.alder'):find('Delete', 1, true), 'wrote to disk')
  vim.cmd('silent undo')
  assert(text(buf) == before, 'one u does not restore the buffer')
end)

test('apply: the position is the one passed, not the window cursor at apply time', function()
  local buf = blog_buf('app/Posts/Index.alder')
  local lsp = require('alder.lsp')
  local orig, sent = lsp.request, {}
  local ok, err = pcall(function()
    lsp.request = function(b, method, params) table.insert(sent, { b = b, method = method, params = params }) end
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    apply.run(buf, 'new msg', { name = 'Delete' }, nil, { 7, 4 })
    apply.run(buf, 'new msg', { name = 'Delete' })
  end)
  lsp.request = orig
  assert(ok, err)
  assert(sent[1].method == 'alder/plan' and sent[1].b == buf, vim.inspect(sent[1]))
  assert(vim.deep_equal(sent[1].params.position, { line = 6, character = 4 }), vim.inspect(sent[1].params))
  assert(sent[1].params.id == 'new msg' and sent[1].params.sets.name == 'Delete', vim.inspect(sent[1].params))
  assert(sent[1].params.textDocument.uri == vim.uri_from_bufnr(buf))
  assert(vim.deep_equal(sent[2].params.position, { line = 2, character = 2 }), vim.inspect(sent[2].params))
end)

test('apply: changed since planning', function()
  local buf = blog_buf('app/Posts/Index.alder')
  vim.fn.search('load params')
  local messages, restore = H.capture_notify()
  local lsp = require('alder.lsp')
  local orig = lsp.request
  local ok, err = pcall(function()
    lsp.request = function(b, method, params, cb)
      orig(b, method, params, function(result)
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '-- typed meanwhile' })
        cb(result)
      end)
    end
    apply.run(buf, 'new msg', { name = 'Delete' })
    H.wait(10000, function() return #messages > 0 end)
  end)
  lsp.request = orig
  restore()
  assert(ok, err)
  assert(messages[1].msg == 'alder: app/Posts/Index.alder changed since planning; nothing applied', vim.inspect(messages))
  assert(not text(buf):find('Delete', 1, true), 'clobbered the edited buffer')
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '-- typed meanwhile')
end)

test('apply: a new page is an unsaved buffer; :w creates its directory', function()
  local buf, root = blog_buf('app/Post.alder')
  local done = false
  local messages, restore = H.capture_notify()
  apply.run(buf, 'new page', { module = 'Tags.Index', path = '/tags' }, function() done = true end)
  H.wait(15000, function() return done end)
  restore()
  assert(done, 'not applied: ' .. vim.inspect(messages))
  local name = vim.api.nvim_buf_get_name(0)
  assert(name == root .. '/app/Tags/Index.alder', name)
  assert(vim.b.alder_new == true)
  assert(vim.bo.buflisted)
  assert(vim.fn.isdirectory(root .. '/app/Tags') == 0, 'directory made before :w')
  assert(vim.fn.filereadable(root .. '/app/Tags/Index.alder') == 0, 'written before :w')
  vim.cmd('silent write')
  assert(vim.fn.filereadable(root .. '/app/Tags/Index.alder') == 1, ':w failed')
  assert(vim.b.alder_new == nil)
end)

test('apply: a refusal is the server text and nothing changes', function()
  local buf = blog_buf('app/Post.alder')
  local before = text(buf)
  local messages, restore = H.capture_notify()
  local ok, err = pcall(function()
    apply.run(buf, 'new page', { module = 'Posts.Index', path = '/x' })
    H.wait(10000, function() return #messages > 0 end)
  end)
  restore()
  assert(ok, err)
  assert(messages[1].msg == 'module `Posts.Index` exists (`app/Posts/Index.alder`): a generator never overwrites a file; choose another module name',
    vim.inspect(messages))
  assert(messages[1].level == vim.log.levels.ERROR)
  assert(text(buf) == before)
end)

-- remove_page opens a fresh page in a blog copy (every blog page is linked from another) and
-- runs `remove page` on it, answering the confirm with answer.
local function remove_page(answer, meanwhile)
  local buf, root = blog_buf('app/Tags/Index.alder', function(dst)
    local r = vim.system({ 'alder', 'new', 'page', 'Tags.Index', '/tags', '--dir', dst }, { text = true }):wait()
    assert(r.code == 0, r.stderr)
  end)
  local orig = vim.ui.select
  local asked, messages, restore
  local done = false
  local ok, err = pcall(function()
    vim.ui.select = function(items, opts, cb)
      asked = { items = items, prompt = opts.prompt }
      if meanwhile then meanwhile() end
      cb(answer)
    end
    messages, restore = H.capture_notify()
    apply.run(buf, 'remove page', { page = 'Tags.Index' }, function() done = true end)
    H.wait(10000, function() return asked ~= nil end)
  end)
  vim.ui.select = orig
  if restore then restore() end
  assert(ok, err)
  return buf, root, asked, messages, done
end

test('apply: remove page asks, and Yes deletes the file and wipes its buffer', function()
  local buf, root, asked, messages, done = remove_page('Yes')
  assert(asked, 'did not ask')
  assert(asked.prompt == 'Delete app/Tags/Index.alder from disk? undo cannot restore it', asked.prompt)
  assert(vim.deep_equal(asked.items, { 'Yes', 'No' }), vim.inspect(asked.items))
  assert(H.wait(5000, function() return done end), 'not applied')
  assert(vim.fn.filereadable(root .. '/app/Tags/Index.alder') == 0, 'not deleted after Yes')
  assert(not vim.api.nvim_buf_is_valid(buf), 'buffer not wiped')
  assert(messages[1].msg == 'alder: applied remove page: app/Tags/Index.alder', vim.inspect(messages))
end)

test('apply: remove page asks, and No applies nothing', function()
  local buf, root, asked, messages, done = remove_page('No')
  assert(asked, 'did not ask')
  H.wait(500, function() return false end)
  assert(not done and #messages == 0, 'applied after No: ' .. vim.inspect(messages))
  assert(vim.fn.filereadable(root .. '/app/Tags/Index.alder') == 1, 'deleted after No')
  assert(vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf), 'buffer wiped after No')
end)

test('apply: remove page re-checks after the confirm; an edit made while it was open aborts', function()
  local buf, root, asked, messages, done = remove_page('Yes', function()
    vim.api.nvim_buf_set_lines(vim.fn.bufnr('Tags/Index.alder'), 0, 0, false, { '-- typed meanwhile' })
  end)
  assert(asked, 'did not ask')
  assert(not done, 'applied over the edit')
  assert(messages[1].msg == 'alder: app/Tags/Index.alder changed since planning; nothing applied', vim.inspect(messages))
  assert(vim.fn.filereadable(root .. '/app/Tags/Index.alder') == 1, 'deleted a changed file')
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '-- typed meanwhile')
end)

test('apply: a nil plan result does nothing', function()
  local buf = blog_buf('app/Post.alder')
  local lsp = require('alder.lsp')
  local orig = lsp.request
  local messages, restore = H.capture_notify()
  local ok, err = pcall(function()
    lsp.request = function(_, _, _, cb) cb(nil); cb(vim.NIL) end
    apply.run(buf, 'new msg', { name = 'Delete' })
  end)
  lsp.request = orig
  restore()
  assert(ok, err)
  assert(#messages == 0, vim.inspect(messages))
end)
