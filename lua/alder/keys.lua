local M = {}

M.actions = {
  generate = function() require('alder.modal').open(0) end,
  diagnostics = function() vim.diagnostic.setqflist({ title = 'alder diagnostics', open = true }) end,
  explain = function() require('alder.check').explain() end,
  run = function() require('alder.commands').alder({ 'run' }) end,
  test = function() require('alder.test').for_current() end,
  test_at = function() require('alder.test').at_cursor() end,
}

local DESC = {
  generate = 'alder: generate (the generator modal)',
  diagnostics = 'alder: diagnostics to quickfix',
  explain = 'alder: explain the diagnostic',
  run = 'alder: run',
  test = 'alder: run the tests',
  test_at = 'alder: run the test under the cursor',
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
    vim.keymap.set('n', lhs, M.actions[name], { buffer = buf, desc = DESC[name] })
  end
  local ok, wk = pcall(require, 'which-key')
  if ok then pcall(wk.add, { { '<leader>a', group = 'alder', buffer = buf } }) end
end

-- detach removes the maps (b:undo_ftplugin).
function M.detach(buf)
  for _, lhs in pairs(mapped()) do pcall(vim.keymap.del, 'n', lhs, { buffer = buf }) end
end

return M
