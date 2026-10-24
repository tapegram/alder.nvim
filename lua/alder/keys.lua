local M = {}

M.actions = {
  generate = function() require('alder.project').generate() end,
  diagnostics = function() vim.diagnostic.setqflist({ title = 'alder diagnostics', open = true }) end,
  explain = function() require('alder.check').explain() end,
  run = function() require('alder.commands').alder({ 'run' }) end,
  test = function() require('alder.test').for_current() end,
  test_at = function() require('alder.test').at_cursor() end,
  mutate = function() require('alder.test').mutate_for_current() end,
  scratch = function()
    local r = require('alder.project').root()
    if r then require('alder.scratch').open(r) end
  end,
  scratch_value = function()
    if require('alder.scratch').is_scratch(0) then require('alder.scratch').open_value() end
  end,
  routes = function() require('alder.routes').pick() end,
  send = function(mode) require('alder.scratch').send_current(mode or 'n') end,
}

-- PROJECT are the actions that need an Alder project but no .alder buffer: they are global maps
-- (attach_global) that say so outside a project. The rest are buffer-local maps in .alder files.
M.PROJECT = { generate = true, run = true, test = true, scratch = true, routes = true }

-- MODES are the modes an action is mapped in (default: normal only); in 'x' the action gets 'x'.
M.MODES = { send = { 'n', 'x' } }

local DESC = {
  generate = 'alder: generate (the generator modal)',
  diagnostics = 'alder: diagnostics to quickfix',
  explain = 'alder: explain the diagnostic',
  run = 'alder: run',
  test = 'alder: run the tests',
  test_at = 'alder: run the test under the cursor',
  mutate = 'alder: mutation testing (survivors to quickfix)',
  scratch = 'alder: open scratch.alder',
  scratch_value = 'alder: open the scratch value at the cursor',
  send = 'alder: send to scratch.alder',
  routes = 'alder: the routes of the app (jump to a page or msg)',
}

local function mapped(project)
  local out = {}
  for name, lhs in pairs(require('alder.config').options.keys or {}) do
    if lhs and M.actions[name] and (M.PROJECT[name] or false) == project then out[name] = lhs end
  end
  return out
end

-- attach maps each configured key buffer-locally and names the which-key group.
function M.attach(buf)
  for name, lhs in pairs(mapped(false)) do
    if name == 'scratch_value' and not require('alder.scratch').is_scratch(buf) then goto continue end
    for _, mode in ipairs(M.MODES[name] or { 'n' }) do
      local rhs = M.actions[name]
      if mode == 'x' then rhs = function() M.actions[name]('x') end end
      vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = DESC[name] })
    end
    ::continue::
  end
  local ok, wk = pcall(require, 'which-key')
  if ok then pcall(wk.add, { { '<leader>a', group = 'alder', buffer = buf } }) end
end

-- detach removes the maps (b:undo_ftplugin).
function M.detach(buf)
  for name, lhs in pairs(mapped(false)) do
    for _, mode in ipairs(M.MODES[name] or { 'n' }) do pcall(vim.keymap.del, mode, lhs, { buffer = buf }) end
  end
end

local global = {} -- the global maps set so far: lhs by action

-- attach_global (re)sets the project-level maps from the config: it removes the ones it set
-- before, so a changed or disabled key takes effect. A map outside a project only says so.
function M.attach_global()
  for _, lhs in pairs(global) do pcall(vim.keymap.del, 'n', lhs) end
  global = {}
  for name, lhs in pairs(mapped(true)) do
    global[name] = lhs
    vim.keymap.set('n', lhs, function()
      if require('alder.project').require_root() then M.actions[name]() end
    end, { desc = DESC[name] })
  end
  local ok, wk = pcall(require, 'which-key')
  if ok then pcall(wk.add, { { '<leader>a', group = 'alder' } }) end
end

return M
