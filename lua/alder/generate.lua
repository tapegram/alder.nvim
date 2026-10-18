local cli = require('alder.cli')
local root = require('alder.root')

local M = {}

-- modified lists the loaded .alder buffers of the app with unsaved changes.
function M.modified(app_root)
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and name:match('%.alder$') and root.find(name) == app_root then
      table.insert(out, buf)
    end
  end
  return out
end

-- render is the preview's text: the files, the migration, the holes, the diagnostics and the
-- diff, all as the compiler printed them.
function M.render(json)
  local lines = {}
  for _, f in ipairs(json.files or {}) do table.insert(lines, f.action .. ' ' .. f.path) end
  if json.migration and #json.migration > 0 then
    table.insert(lines, '')
    table.insert(lines, 'migration:')
    for _, step in ipairs(json.migration) do table.insert(lines, '  ' .. step) end
  end
  if json.holes and #json.holes > 0 then
    table.insert(lines, '')
    for _, h in ipairs(json.holes) do
      local addr = h.module .. '.' .. h.decl .. (h.arm and ('.' .. h.arm) or '')
      table.insert(lines, ('hole %s ?%s : %s  (%s:%d:%d)'):format(addr, h.name, h.type, h.file, h.line, h.col))
    end
  end
  if json.diagnostics and #json.diagnostics > 0 then
    table.insert(lines, '')
    for _, d in ipairs(json.diagnostics) do
      table.insert(lines, ('%s:%d:%d %s %s'):format(d.file, d.line, d.col, d.code, d.message))
    end
  end
  if json.diff and json.diff ~= '' then
    table.insert(lines, '')
    vim.list_extend(lines, vim.split(json.diff, '\n', { plain = true }))
  end
  return lines
end

-- after_write reloads edited buffers, opens the first created file and re-checks the app.
function M.after_write(app_root, json)
  vim.cmd('checktime')
  for _, f in ipairs(json.files or {}) do
    if f.action == 'created' and f.path:match('%.alder$') then
      vim.cmd.edit(vim.fn.fnameescape(app_root .. '/' .. f.path))
      break
    end
  end
  require('alder.check').run(app_root)
end

local pending = {} -- preview buffer → { fargs, app_root, stdin }

function M.apply_preview(buf)
  local p = pending[buf]
  if not p then return end
  pending[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  M.run(p.fargs, { preview = false, app_root = p.app_root, stdin = p.stdin })
end

-- show_preview opens alder://preview (any earlier one is wiped by cli.scratch). With
-- readonly there is nothing to apply, and <CR> says so.
local function show_preview(app_root, fargs, json, o)
  o = o or {}
  local head = o.readonly and 'read-only, nothing to apply; q closes' or '<CR> applies, q discards'
  local lines = { ('-- %s: alder %s'):format(head, table.concat(fargs, ' ')), '' }
  vim.list_extend(lines, M.render(json))
  local buf = cli.scratch('alder://preview', lines, 'diff')
  if o.readonly then
    vim.keymap.set('n', '<CR>', function() vim.notify('alder: nothing to apply, this output is read-only', vim.log.levels.INFO) end,
      { buffer = buf, nowait = true })
    return
  end
  pending[buf] = { fargs = fargs, app_root = app_root, stdin = o.stdin }
  vim.keymap.set('n', '<CR>', function() M.apply_preview(buf) end, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() pending[buf] = nil end })
end

-- refusal_list puts a refusal's diagnostics in a new quickfix list titled `alder <cmd>`. They
-- describe the dry-run copy, not the buffers, so they are never published as diagnostics and
-- the user's lists (and `alder check`'s) stay in the stack.
local function refusal_list(app_root, fargs, diagnostics)
  local items = {}
  for _, d in ipairs(diagnostics or {}) do
    table.insert(items, { filename = app_root .. '/' .. d.file, lnum = d.line, col = d.col,
      text = d.code .. ' ' .. d.message, type = d.severity == 'warning' and 'W' or 'E' })
  end
  if #items == 0 then return end
  vim.fn.setqflist({}, ' ', { title = 'alder ' .. fargs[1], items = items })
  vim.cmd('copen')
end

-- run is a generator (`new <kind>`, `edit`, `remove`, `fill`, `regen`). It refuses while any
-- .alder buffer of the app has unsaved changes (the CLI edits files on disk), runs from the
-- app root with --json --dir, and with preview on shows the --dry-run diff first.
function M.run(fargs, o)
  o = o or {}
  local app_root = o.app_root or root.for_buf(0)
  if not app_root then
    vim.notify('alder: no `app/` directory above this file', vim.log.levels.ERROR)
    return
  end
  if #M.modified(app_root) > 0 then
    vim.notify('alder: save all buffers first (:wall)', vim.log.levels.ERROR)
    return
  end
  local preview = o.preview
  if preview == nil then preview = require('alder.config').options.preview end
  local asked_dry = vim.tbl_contains(fargs, '--dry-run')
  local args = vim.deepcopy(fargs)
  if not vim.tbl_contains(args, '--json') then table.insert(args, '--json') end
  vim.list_extend(args, { '--dir', app_root })
  if preview and not asked_dry then table.insert(args, '--dry-run') end
  cli.run(args, { cwd = app_root, stdin = o.stdin }, function(res)
    local json = res.json
    if not json or res.code == 2 then
      cli.report(args, res)
      if o.on_done then o.on_done(res) end
      return
    end
    if json.error then
      vim.notify(json.error, vim.log.levels.ERROR)
      refusal_list(app_root, fargs, json.diagnostics)
    elseif fargs[1] == 'fill' and vim.tbl_contains(fargs, '--list') then
      show_preview(app_root, fargs, json, { readonly = true })
    elseif asked_dry then
      show_preview(app_root, fargs, json, { readonly = true })
    elseif preview then
      show_preview(app_root, fargs, json, { stdin = o.stdin })
    else
      M.after_write(app_root, json)
    end
    if o.on_done then o.on_done(res) end
  end)
end

-- ask runs the prompts in order, each a function(done) that calls done(value|nil); nil stops.
local function ask(steps, finish)
  local values = {}
  local function step(i)
    if i > #steps then return finish(values) end
    steps[i](function(v)
      if v == nil then return end
      table.insert(values, v)
      step(i + 1)
    end)
  end
  step(1)
end

-- new_interactive is :AlderNew: pick a generator, type its arguments, add flags, preview.
function M.new_interactive()
  local new = require('alder.commands').find({ 'new' })
  if not new then
    vim.notify('alder: `alder help --json` failed; is alder on PATH and recent enough?', vim.log.levels.ERROR)
    return
  end
  vim.ui.select(new.subcommands or {}, {
    prompt = 'alder new',
    format_item = function(c) return c.name .. ' — ' .. c.summary end,
  }, function(kind)
    if not kind then return end
    local steps = {}
    for _, a in ipairs(kind.args or {}) do
      table.insert(steps, function(done)
        vim.ui.input({ prompt = a .. ': ' }, function(v)
          if v == nil then return done(nil) end
          if v == '' and a:match('^%[') then return done({}) end
          if v == '' then return done(nil) end
          -- a variadic argument (`<field>:<Type>…`) is several words; any other is one
          done(a:match('…$') and vim.split(vim.trim(v), '%s+') or { v })
        end)
      end)
    end
    ask(steps, function(values)
      local fargs = { 'new', kind.name }
      for _, v in ipairs(values) do vim.list_extend(fargs, v) end
      local function more()
        local choices = { { name = 'done' } }
        for _, f in ipairs(kind.flags or {}) do
          if f.name ~= '--dir' and f.name ~= '--json' and f.name ~= '--dry-run' then table.insert(choices, f) end
        end
        vim.ui.select(choices, {
          prompt = 'alder new ' .. kind.name .. ': add a flag',
          format_item = function(f) return f.summary and (f.name .. (f.value and (' ' .. f.value) or '') .. ' — ' .. f.summary) or f.name end,
        }, function(f)
          if not f then return end
          if f.name == 'done' then return M.run(fargs) end
          if not f.value then
            table.insert(fargs, f.name)
            return more()
          end
          vim.ui.input({ prompt = f.name .. ' ' .. f.value .. ': ' }, function(v)
            if v and v ~= '' then vim.list_extend(fargs, { f.name, v }) end
            more()
          end)
        end)
      end
      more()
    end)
  end)
end

return M
