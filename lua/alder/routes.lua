-- routes: the route picker (<leader>au, :AlderRoutes) — every page and msg route of the app,
-- fuzzy-filtered on the path, jumping to its declaration. The routes come from the server
-- (`alder/routes`), else from `alder routes --json`.
local picker = require('alder.picker')
local project = require('alder.project')

local M = {}
M.state = nil
local ns = vim.api.nvim_create_namespace('alder.routes')

-- item: { kind, path, module, name, file (absolute), lnum (1-based), col (0-based) }

function M.normalize_lsp(result)
  local out = {}
  for _, r in ipairs(result or {}) do
    local start = r.range and r.range.start or { line = 0, character = 0 }
    out[#out + 1] = { kind = r.kind, path = r.path, module = r.module, name = r.name,
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
    out[#out + 1] = { kind = r.kind, path = r.path, module = r.module, name = r.name,
      file = file, lnum = r.line or 1, col = math.max((r.col or 1) - 1, 0) }
  end
  return out
end

local function verb(r) return r.kind == 'msg' and 'POST' or 'GET' end

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
function M.fetch(root, cb)
  local c = require('alder.lsp').project_client(root, vim.api.nvim_get_current_buf())
  if c then
    local sent = c:request('alder/routes', vim.empty_dict(), function(err, result)
      if err then return cb(nil, err.message) end
      cb(M.normalize_lsp(require('alder.ui').plain(result) or {}))
    end)
    if sent ~= false then return end
  end
  local cli = require('alder.cli')
  cli.run({ 'routes', '--json' }, { cwd = root }, function(res)
    if res.code ~= 0 then return cb(nil, vim.trim(res.stderr ~= '' and res.stderr or res.stdout)) end
    -- a JSON array (or {routes=…}) is decoded whole; cli.decode (res.objects) only reads JSONL
    local ok, v = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
    local objects
    if ok and type(v) == 'table' then objects = (v.routes or v) else objects = res.objects end
    if objects and objects.kind then objects = { objects } end
    cb(M.normalize_cli(objects, root))
  end)
end

-- ── The picker ───────────────────────────────────────────────────────────────

local function render()
  local s = M.state
  if not s or not vim.api.nvim_buf_is_valid(s.list_buf) then return end
  local lines = M.lines(s.filtered)
  vim.bo[s.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.list_buf, 0, -1, false, #lines > 0 and lines or { '' })
  vim.bo[s.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.list_buf, ns, 0, -1)
  if #s.filtered > 0 then
    s.selected = math.max(1, math.min(s.selected, #s.filtered))
    vim.api.nvim_buf_set_extmark(s.list_buf, ns, s.selected - 1, 0, { line_hl_group = 'PmenuSel' })
    pcall(vim.api.nvim_win_set_cursor, s.list_win, { s.selected, 0 })
  end
  pcall(vim.api.nvim_win_set_config, s.list_win, { footer = (' %d of %d '):format(#s.filtered, #s.items), footer_pos = 'right' })
end

function M.close()
  local s = M.state
  if not s then return end
  M.state = nil
  vim.cmd.stopinsert()
  for _, w in ipairs({ s.search_win, s.list_win }) do
    if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  if vim.api.nvim_win_is_valid(s.origin) then pcall(vim.api.nvim_set_current_win, s.origin) end
end

function M.set_query(q)
  local s = M.state
  if not s then return end
  s.query = q
  s.filtered = M.filter(s.items, q)
  s.selected = 1
  render()
end

function M.move(delta)
  local s = M.state
  if not s or #s.filtered == 0 then return end
  s.selected = ((s.selected - 1 + delta) % #s.filtered) + 1
  render()
end

-- jump opens the route's declaration.
function M.jump(r)
  vim.cmd.edit(vim.fn.fnameescape(r.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { r.lnum, r.col })
  vim.cmd('normal! zv')
end

function M.confirm()
  local s = M.state
  if not s then return end
  local r = s.filtered[s.selected]
  M.close()
  if r then M.jump(r) end
end

-- show opens the picker over items.
function M.show(items)
  M.close()
  if #items == 0 then return vim.notify('alder: no routes', vim.log.levels.INFO) end
  local origin = vim.api.nvim_get_current_win()
  local width = math.min(math.floor(vim.o.columns * 0.8), 120)
  local height = math.min(#items, math.max(5, math.floor(vim.o.lines * 0.5)))
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.max(1, math.floor((vim.o.lines - height - 6) / 2))
  local function float(buf, enter, r, h, title)
    local cfg = { relative = 'editor', row = r, col = col, width = width, height = h, style = 'minimal', border = 'rounded' }
    if title then cfg.title, cfg.title_pos = title, 'left' end
    return vim.api.nvim_open_win(buf, enter, cfg)
  end
  local search_buf = vim.api.nvim_create_buf(false, true)
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].modifiable = false
  local search_win = float(search_buf, true, row, 1, ' Routes ')
  local list_win = float(list_buf, false, row + 3, height, nil)
  vim.wo[list_win].cursorline = false
  M.state = { items = items, filtered = vim.list_slice(items), selected = 1, query = '', origin = origin,
    search_buf = search_buf, list_buf = list_buf, search_win = search_win, list_win = list_win }
  vim.b[search_buf].completion = false
  local function map(lhs, fn) vim.keymap.set({ 'i', 'n' }, lhs, fn, { buffer = search_buf, nowait = true }) end
  map('<CR>', M.confirm)
  map('<Esc>', M.close)
  map('<C-c>', M.close)
  map('<Down>', function() M.move(1) end)
  map('<C-n>', function() M.move(1) end)
  map('<Up>', function() M.move(-1) end)
  map('<C-p>', function() M.move(-1) end)
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, { buffer = search_buf, callback = function()
    if M.state then M.set_query(vim.api.nvim_buf_get_lines(search_buf, 0, 1, false)[1] or '') end
  end })
  vim.api.nvim_create_autocmd('BufLeave', { buffer = search_buf, once = true, callback = function() vim.schedule(M.close) end })
  render()
  vim.cmd.startinsert()
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
