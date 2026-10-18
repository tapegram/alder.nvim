local commands = require('alder.commands')

local function has(list, x) return vim.tbl_contains(list, x) end

test('completion: commands, generators and flags from alder help --json', function()
  assert(commands.tree(), 'alder help --json failed: is the alder on PATH built from the m6a branch?')
  local top = commands.complete('', 'Alder ')
  assert(has(top, 'check') and has(top, 'new') and has(top, 'fill'), vim.inspect(top))
  local gens = commands.complete('', 'Alder new ')
  assert(has(gens, 'page') and has(gens, 'table'), vim.inspect(gens))
  local flags = commands.complete('--l', 'Alder new page --l')
  assert(has(flags, '--list') and not has(flags, '--json'), vim.inspect(flags))
  assert(#commands.complete('', 'Alder new page --list ') == 0, 'a flag value is free text')
end)

test('completion: keypresses never spawn alder; :Alder re-checks the version', function()
  commands.tree()
  local spawned, orig = 0, vim.system
  vim.system = function(...) spawned = spawned + 1 return orig(...) end
  for _ = 1, 3 do
    commands.complete('', 'Alder ')
    commands.complete('--l', 'Alder new page --l')
  end
  assert(spawned == 0, 'completion spawned ' .. spawned)
  commands.refresh()
  vim.system = orig
  assert(spawned == 1, 'refresh should only run alder version, spawned ' .. spawned)
end)

test('completion: --from takes free text', function()
  local node = commands.find({ 'restore' })
  assert(node, 'restore not in the tree')
  assert(#commands.complete('', 'Alder restore --from ') == 0)
end)
