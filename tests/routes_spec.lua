local H = require('helpers')
local config = require('alder.config')
local routes = require('alder.routes')

local function lsp_result(root)
  return {
    { kind = 'page', path = '/sites/:id', module = 'Sites.Clarity.Index', name = 'page', uri = vim.uri_from_fname(root .. '/app/Sites/Clarity/Index.alder'),
      range = { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 6 } } },
    { kind = 'msg', path = '/sites/:id/delete', module = 'Sites.Clarity.Index', name = 'Delete', uri = vim.uri_from_fname(root .. '/app/Sites/Clarity/Index.alder'),
      range = { start = { line = 2, character = 0 }, ['end'] = { line = 2, character = 3 } } },
  }
end

local function project()
  local root = H.tmpdir() .. '/proj'
  H.write(root .. '/app/App.alder', 'module App\n')
  H.write(root .. '/app/Sites/Clarity/Index.alder', 'module Sites.Clarity.Index\n  page = 1\nDelete = 2\n')
  return root
end

-- with_cwd runs f in dir, restoring the cwd.
local function with_cwd(dir, f)
  local old = vim.fn.getcwd()
  vim.cmd.cd(dir)
  local ok, err = pcall(f)
  vim.cmd.cd(old)
  if not ok then error(err, 0) end
end

test('routes: project_client never returns another project\'s client', function()
  local lsp = require('alder.lsp')
  local saved = vim.lsp.get_clients
  vim.lsp.get_clients = function() return { { name = 'alder', root_dir = '/other/proj' } } end
  local got, same
  local ok, err = pcall(function()
    got = lsp.project_client('/this/proj')
    same = lsp.project_client('/other/proj')
  end)
  vim.lsp.get_clients = saved
  assert(ok, err)
  assert(got == nil, vim.inspect(got))
  assert(same and same.root_dir == '/other/proj')
end)

test('routes: label shows the verb, the path and the declaration', function()
  local items = routes.normalize_lsp(lsp_result('/x'))
  assert(routes.label(items[1]) == 'GET /sites/:id  Sites.Clarity.Index.page', routes.label(items[1]))
  assert(routes.label(items[2]) == 'POST /sites/:id/delete  Sites.Clarity.Index.Delete', routes.label(items[2]))
  assert(items[1].file == '/x/app/Sites/Clarity/Index.alder' and items[1].lnum == 2 and items[1].col == 2, vim.inspect(items[1]))
end)

test('routes: normalize_cli makes the file absolute and the position 0-based in the column', function()
  local items = routes.normalize_cli({ { kind = 'page', path = '/', module = 'Home', name = 'page', file = 'app/Home.alder', line = 3, col = 5 } }, '/proj')
  assert(items[1].file == '/proj/app/Home.alder' and items[1].lnum == 3 and items[1].col == 4, vim.inspect(items[1]))
end)

test('routes: filter is a fuzzy match on the path', function()
  local items = routes.normalize_lsp(lsp_result('/x'))
  assert(#routes.filter(items, '') == 2)
  local got = routes.filter(items, 'delete')
  assert(#got == 1 and got[1].name == 'Delete', vim.inspect(got))
  assert(#routes.filter(items, 'zzzz') == 0)
end)

test('routes: fetch sends alder/routes {} to the project client and normalizes the answer', function()
  local root = project()
  local lsp = require('alder.lsp')
  local saved, sent = lsp.project_client, {}
  lsp.project_client = function() return { request = function(_, method, params, handler)
    sent = { method = method, params = params }
    handler(nil, lsp_result(root))
    return true
  end } end
  local got
  local ok, err = pcall(function()
    routes.fetch(root, function(items) got = items end)
    assert(H.wait(2000, function() return got ~= nil end), 'no answer')
  end)
  lsp.project_client = saved
  assert(ok, err)
  assert(sent.method == 'alder/routes' and vim.deep_equal(sent.params, vim.empty_dict()), vim.inspect(sent))
  assert(#got == 2 and got[2].kind == 'msg' and got[2].lnum == 3, vim.inspect(got))
end)

test('routes: with no client fetch falls back to alder routes --json', function()
  local root = project()
  local script = H.tmpdir() .. '/fake-alder'
  H.write(script, '#!/bin/sh\n[ "$1 $2" = "routes --json" ] || exit 2\n'
    .. [[echo '[{"kind":"page","path":"/sites/:id","module":"Sites.Clarity.Index","name":"page","file":"app/Sites/Clarity/Index.alder","line":2,"col":3}]']] .. '\n')
  vim.uv.fs_chmod(script, tonumber('755', 8))
  local lsp, saved, cmd = require('alder.lsp'), require('alder.lsp').project_client, config.options.cmd
  lsp.project_client = function() return nil end
  config.options.cmd = script
  local got
  local ok, err = pcall(function()
    routes.fetch(root, function(items) got = items end)
    assert(H.wait(5000, function() return got ~= nil end), 'no answer')
  end)
  lsp.project_client, config.options.cmd = saved, cmd
  assert(ok, err)
  assert(#got == 1 and got[1].file == root .. '/app/Sites/Clarity/Index.alder' and got[1].lnum == 2 and got[1].col == 2, vim.inspect(got))
end)

-- an LSP client whose server answers alder/routes with an error (an older alder: MethodNotFound)
local function failing_client()
  return { request = function(_, _, _, handler)
    handler({ code = -32601, message = 'unknown method alder/routes' }, nil)
    return true
  end }
end

test('routes: an LSP error falls back to alder routes --json', function()
  local root = project()
  local script = H.tmpdir() .. '/fake-alder'
  H.write(script, '#!/bin/sh\n[ "$1 $2" = "routes --json" ] || exit 2\n'
    .. [[echo '[{"kind":"page","path":"/sites/:id","module":"Sites.Clarity.Index","name":"page","file":"app/Sites/Clarity/Index.alder","line":2,"col":3}]']] .. '\n')
  vim.uv.fs_chmod(script, tonumber('755', 8))
  local lsp, saved, cmd = require('alder.lsp'), require('alder.lsp').project_client, config.options.cmd
  lsp.project_client = failing_client
  config.options.cmd = script
  local got
  local ok, err = pcall(function()
    routes.fetch(root, function(items) got = items end)
    assert(H.wait(5000, function() return got ~= nil end), 'no answer')
  end)
  lsp.project_client, config.options.cmd = saved, cmd
  assert(ok, err)
  assert(#got == 1 and got[1].lnum == 2, vim.inspect(got))
end)

test('routes: an alder too old for routes says to update it and restart the LSP', function()
  local root = project()
  local script = H.tmpdir() .. '/old-alder'
  H.write(script, '#!/bin/sh\necho "usage: alder new <name> | alder check [dir]" >&2\nexit 2\n')
  vim.uv.fs_chmod(script, tonumber('755', 8))
  local lsp, saved, cmd = require('alder.lsp'), require('alder.lsp').project_client, config.options.cmd
  lsp.project_client = failing_client
  config.options.cmd = script
  local done, msg
  local ok, err = pcall(function()
    routes.fetch(root, function(items, e) done, msg = true, e; assert(items == nil) end)
    assert(H.wait(5000, function() return done end), 'no answer')
  end)
  lsp.project_client, config.options.cmd = saved, cmd
  assert(ok, err)
  assert(msg:find('update alder', 1, true) and msg:find(':LspRestart', 1, true), msg)
end)

test('routes: pick lists the routes, filters on the path and jumps to the choice', function()
  local root = project()
  local items = routes.normalize_lsp(lsp_result(root))
  routes.show(items)
  local ok, err = pcall(function()
    local text = H.float_text()
    assert(text:find('GET /sites/:id +Sites.Clarity.Index.page'), text)
    assert(text:find('POST /sites/:id/delete', 1, true), text)
    routes.set_query('delete')
    assert(not H.float_text():find('GET /sites/:id ', 1, true), H.float_text())
    routes.confirm()
    assert(vim.api.nvim_buf_get_name(0) == root .. '/app/Sites/Clarity/Index.alder', vim.api.nvim_buf_get_name(0))
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 0 }), vim.inspect(vim.api.nvim_win_get_cursor(0)))
    assert(routes.state == nil, 'picker did not close')
  end)
  routes.close()
  assert(ok, err)
end)

test('routes: pick outside an Alder project says so', function()
  with_cwd(H.tmpdir(), function()
    vim.cmd.enew()
    local messages, restore = H.capture_notify()
    local ok, err = pcall(routes.pick)
    restore()
    assert(ok, err)
    assert(messages[1] and messages[1].msg == 'alder: not in an Alder project', vim.inspect(messages))
  end)
end)

test('routes: <leader>au and :AlderRoutes exist', function()
  vim.g.mapleader = ' '
  assert(vim.fn.exists(':AlderRoutes') == 2)
  assert(vim.fn.maparg(vim.keycode('<leader>au'), 'n') ~= '', '<leader>au not mapped')
end)
