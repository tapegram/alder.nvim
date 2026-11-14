-- routes: the route picker (<leader>au, :AlderRoutes) — every page and msg route of the app,
-- fuzzy-filtered on the path, jumping to its declaration. The routes come from the server
-- (`alder/routes`), else from `alder routes --json`.
local picker = require('alder.picker')
local project = require('alder.project')

local M = {}
M.state = nil

-- item: { kind, method (may be nil), path, module, name, file (absolute), lnum (1-based), col (0-based) }

function M.normalize_lsp(result)
  local out = {}
  for _, r in ipairs(result or {}) do
    local start = r.range and r.range.start or { line = 0, character = 0 }
    out[#out + 1] = { kind = r.kind, method = r.method, path = r.path, module = r.module, name = r.name,
      file = vim.uri_to_fname(r.uri), lnum = start.line + 1, col = start.character }
  end
  return out
end

-- normalize_cli: the CLI's objects carry a root-relative `file` and a 1-based `line` and `col`.
function M.normalize_cli(objects, root)
  local out = {}
  for _, r in ipairs(objects or {}) do
    local file = r.file or ''
    if not vim.startswith(file, '/') then file = root .. '/' .. file end
    out[#out + 1] = { kind = r.kind, method = r.method, path = r.path, module = r.module, name = r.name,
      file = file, lnum = r.line or 1, col = math.max((r.col or 1) - 1, 0) }
  end
  return out
end

-- verb: the route's method, else (an alder older than `route`) POST for a msg and GET otherwise.
local function verb(r) return r.method or (r.kind == 'msg' and 'POST' or 'GET') end

function M.label(r)
  return ('%s %s  %s.%s'):format(verb(r), r.path, r.module, r.name)
end

function M.filter(items, query)
  return picker.filter(items, query, function(r) return r.path .. ' ' .. r.module .. '.' .. r.name end)
end

-- lines aligns the declarations after the longest `VERB /path`.
function M.lines(items)
  local width = 0
  for _, r in ipairs(items) do width = math.max(width, #verb(r) + 1 + #r.path) end
  local out = {}
  for i, r in ipairs(items) do
    local head = verb(r) .. ' ' .. r.path
    out[i] = head .. string.rep(' ', width - #head + 2) .. r.module .. '.' .. r.name
  end
  return out
end

-- fetch calls cb(items) with the routes of the app at root, or cb(nil, message) on failure.
-- The LSP is asked first; if there is no client or it answers with an error (an alder older
-- than alder/routes), the CLI is tried.
function M.fetch(root, cb)
  local c = require('alder.lsp').project_client(root, vim.api.nvim_get_current_buf())
  if c then
    local sent = c:request('alder/routes', vim.empty_dict(), function(err, result)
      if err then return M.fetch_cli(root, cb, err) end
      cb(M.normalize_lsp(require('alder.ui').plain(result) or {}))
    end)
    if sent ~= false then return end
  end
  M.fetch_cli(root, cb)
end

-- fetch_cli runs `alder routes --json`. lsp_err is the LSP's error when it was asked first: if
-- both fail, the server and the binary predate routes, so the message says how to fix that.
function M.fetch_cli(root, cb, lsp_err)
  local cli = require('alder.cli')
  cli.run({ 'routes', '--json' }, { cwd = root }, function(res)
    if res.code ~= 0 then
      if lsp_err then
        return cb(nil, 'this alder has no routes command (' .. lsp_err.message .. '): update alder'
          .. ' (go install ./cmd/alder in the alder repo), then :LspRestart')
      end
      return cb(nil, vim.trim(res.stderr ~= '' and res.stderr or res.stdout))
    end
    -- a JSON array (or {routes=…}) is decoded whole; cli.decode (res.objects) only reads JSONL
    local ok, v = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
    local objects
    if ok and type(v) == 'table' then objects = (v.routes or v) else objects = res.objects end
    if objects and objects.kind then objects = { objects } end
    cb(M.normalize_cli(objects, root))
  end)
end

-- ── The picker ───────────────────────────────────────────────────────────────

-- M.state is the open picker (alder.picker), nil when none is open.

function M.close()
  if M.state then M.state:close() end
end

function M.set_query(q)
  if M.state then M.state:set_query(q) end
end

function M.move(delta)
  if M.state then M.state:move(delta) end
end

-- jump opens the route's declaration.
function M.jump(r)
  vim.cmd.edit(vim.fn.fnameescape(r.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { r.lnum, r.col })
  vim.cmd('normal! zv')
end

function M.confirm()
  if M.state then M.state:confirm() end
end

-- show opens the picker over items: `VERB /path` and the declaration, filtered on the path.
function M.show(items)
  M.close()
  if #items == 0 then return vim.notify('alder: no routes', vim.log.levels.INFO) end
  local p
  p = picker.open({
    title = 'Routes',
    source = { items = items, filter = M.filter },
    row = function(r) return verb(r) .. ' ' .. r.path, r.module .. '.' .. r.name end,
    on_pick = M.jump,
    on_close = function() if M.state == p then M.state = nil end end,
  })
  M.state = p
end

-- pick fetches the routes of the current project and shows the picker.
function M.pick()
  local root = project.require_root()
  if not root then return end
  M.fetch(root, function(items, err)
    if not items then return vim.notify('alder routes: ' .. (err or 'failed'), vim.log.levels.ERROR) end
    M.show(items)
  end)
end

return M
