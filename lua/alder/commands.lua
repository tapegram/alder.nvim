local cli = require('alder.cli')

local M = {}

local cache = { version = nil, tree = nil, failed = false }

local function version_of(cmd)
  local v = vim.system({ cmd, 'version' }, { text = true }):wait()
  return vim.trim(v.stdout or '')
end

-- decode_tree returns the command tree printed by `alder help --json`, or nil when stdout is
-- not that JSON (an alder from before editor support exits 0 and prints text).
function M.decode_tree(stdout)
  local ok, t = pcall(vim.json.decode, stdout or '', { luanil = { object = true, array = true } })
  if ok and type(t) == 'table' and type(t.commands) == 'table' then return t end
end

local function load(cmd)
  cache.failed = true
  local r = vim.system({ cmd, 'help', '--json' }, { text = true }):wait()
  if r.code ~= 0 then return end
  local t = M.decode_tree(r.stdout)
  if not t then return end
  cache.version, cache.tree, cache.failed = version_of(cmd), t, false
end

-- tree is `alder help --json`, cached for the session. Completion calls this on every
-- keypress, so it never spawns `alder version`: only the first call (and a retry after
-- refresh) runs `alder help --json`. A failed load is not retried until refresh().
function M.tree()
  if cache.tree then return cache.tree end
  if cache.failed then return nil end
  local cmd = require('alder.config').options.cmd
  if vim.fn.executable(cmd) ~= 1 then return nil end
  load(cmd)
  return cache.tree
end

-- refresh re-checks `alder version` and reloads the tree when it changed (or never loaded).
-- Only :Alder calls it.
function M.refresh()
  local cmd = require('alder.config').options.cmd
  if vim.fn.executable(cmd) ~= 1 then return nil end
  if not cache.tree or cache.version ~= version_of(cmd) then load(cmd) end
  return cache.tree
end

local function child(list, name)
  for _, c in ipairs(list or {}) do
    if c.name == name then return c end
  end
end

-- find_in walks tree along words (`{'new', 'page'}`) and returns the deepest command reached.
local function find_in(t, words)
  if not t then return nil end
  local node, list = nil, t.commands
  for _, w in ipairs(words) do
    local c = child(list, w)
    if not c then break end
    node, list = c, c.subcommands
  end
  return node
end

-- find is find_in on the session's cached tree.
function M.find(words) return find_in(M.tree(), words) end

local function flag(node, name)
  for _, f in ipairs(node and node.flags or {}) do
    if f.name == name then return f end
  end
end

-- tree_has_flag reports whether the command at words in tree (a decoded `alder help --json`)
-- lists the flag; only that exact command counts, not an ancestor reached instead.
function M.tree_has_flag(tree, words, name)
  local node = find_in(tree, words)
  return node ~= nil and node.name == words[#words] and flag(node, name) ~= nil
end

-- has_flag is tree_has_flag on the session's cached tree.
function M.has_flag(words, name) return M.tree_has_flag(M.tree(), words, name) end

function M.complete(arglead, cmdline)
  local t = M.tree()
  if not t then return {} end
  local words = vim.split(vim.trim(cmdline), '%s+')
  table.remove(words, 1) -- the command name
  if arglead ~= '' then table.remove(words) end
  local node, list = nil, t.commands
  for _, w in ipairs(words) do
    local c = not w:match('^%-') and child(list, w)
    if c then node, list = c, c.subcommands else list = nil end
  end
  local prev = words[#words]
  local f = prev and flag(node, prev)
  if f and f.value then return {} end -- a flag's value is free text
  local out = {}
  for _, c in ipairs(list or {}) do table.insert(out, c.name) end
  for _, fl in ipairs(node and node.flags or {}) do table.insert(out, fl.name) end
  return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, out)
end

local GENERATORS = { new = true, edit = true, remove = true, fill = true, regen = true }
local TERMINAL = { run = true, repl = true }

-- alder is :Alder <args…>: generators preview and apply, check publishes diagnostics,
-- long-running commands get a terminal, everything else prints its output verbatim.
function M.alder(fargs)
  local name = fargs[1]
  if not name then
    vim.notify('alder: :Alder <command> [args…]', vim.log.levels.WARN)
    return
  end
  if not cli.available() then return end
  M.refresh()
  local app_root = require('alder.project').root(0)
  if name == 'check' then
    require('alder.check').for_current({ open_qf = true })
    return
  end
  if TERMINAL[name] or (name == 'logs' and vim.tbl_contains(fargs, '-f')) then
    vim.cmd('botright new')
    local argv = { require('alder.config').options.cmd }
    vim.list_extend(argv, fargs)
    vim.fn.jobstart(argv, { term = true, cwd = app_root or vim.fn.getcwd() })
    vim.cmd('startinsert')
    return
  end
  if name == 'fill' and vim.tbl_contains(fargs, '-') then
    -- the CLI reads the expression from stdin, which a command line cannot give (and it refuses empty input)
    vim.notify('`alder fill … -` reads stdin: run it in a terminal', vim.log.levels.ERROR)
    return
  end
  -- `new <name>` (not a generator kind) scaffolds an app, from the current directory
  local new = M.find({ 'new' })
  if name == 'new' and fargs[2] ~= nil and not new then
    -- without the tree a generator cannot be told from app scaffolding: run nothing
    vim.notify('alder: `alder help --json` failed; is alder on PATH and recent enough?', vim.log.levels.ERROR)
    return
  end
  local scaffold = name == 'new' and fargs[2] ~= nil and not (new and child(new.subcommands, fargs[2]))
  if GENERATORS[name] and not scaffold then
    require('alder.generate').run(fargs)
    return
  end
  local cwd = (scaffold or not app_root) and vim.fn.getcwd() or app_root
  cli.run(fargs, { cwd = cwd }, function(res)
    local text = res.stdout .. (res.stderr ~= '' and ('\n' .. res.stderr) or '')
    cli.scratch('alder://' .. name, vim.split(vim.trim(text), '\n', { plain = true }))
  end)
end

return M
