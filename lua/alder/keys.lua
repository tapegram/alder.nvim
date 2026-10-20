local M = {}

M.actions = {
  generate = function() require('alder.modal').open(0) end,
  diagnostics = function() vim.diagnostic.setqflist({ title = 'alder diagnostics', open = true }) end,
  explain = function() require('alder.check').explain() end,
  run = function() require('alder.commands').alder({ 'run' }) end,
  test = function() require('alder.test').for_current() end,
  test_at = function() require('alder.test').at_cursor() end,
  mutate = function() require('alder.test').mutate_for_current() end,
  repl = function() require('alder.repl').for_current() end,
  send = function(mode) require('alder.repl').send_current(mode or 'n') end,
}

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
  repl = 'alder: the REPL in this module',
  send = 'alder: send to the REPL',
}

local function mapped()
  local out = {}
  for name, lhs in pairs(require('alder.config').options.keys or {}) do
    if lhs and M.actions[name] then out[name] = lhs end
  end
  return out
end

-- attach maps each configured key buffer-locally and names the which-key group.
function M.attach(buf)
  for name, lhs in pairs(mapped()) do
    for _, mode in ipairs(M.MODES[name] or { 'n' }) do
      local rhs = M.actions[name]
      if mode == 'x' then rhs = function() M.actions[name]('x') end end
      vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = DESC[name] })
    end
  end
  local ok, wk = pcall(require, 'which-key')
  if ok then pcall(wk.add, { { '<leader>a', group = 'alder', buffer = buf } }) end
end

-- detach removes the maps (b:undo_ftplugin).
function M.detach(buf)
  for name, lhs in pairs(mapped()) do
    for _, mode in ipairs(M.MODES[name] or { 'n' }) do pcall(vim.keymap.del, mode, lhs, { buffer = buf }) end
  end
end

return M
