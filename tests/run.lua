-- tests/run.lua (prefer tests/run.sh, which isolates temp dirs and picks alder): nvim --headless -u tests/minimal.lua -l tests/run.lua [pattern]
-- Loads tests/*_spec.lua, runs each `test(name, fn)` whose name matches the pattern, prints
-- ok/FAIL per test, and exits non-zero when any fails.
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
package.path = here .. '/?.lua;' .. package.path
local cases = {}
_G.test = function(name, fn) table.insert(cases, { name = name, fn = fn }) end
for _, f in ipairs(vim.fn.glob(here .. '/*_spec.lua', false, true)) do dofile(f) end
local pattern = _G.arg and _G.arg[1] or os.getenv('ALDER_TEST')
local failed, ran = 0, 0
for _, c in ipairs(cases) do
  if not pattern or c.name:find(pattern, 1, true) then
    ran = ran + 1
    local ok, err = xpcall(c.fn, debug.traceback)
    io.stdout:write((ok and 'ok   ' or 'FAIL ') .. c.name .. '\n')
    if not ok then
      failed = failed + 1
      io.stdout:write(tostring(err) .. '\n')
    end
    vim.cmd('silent! %bwipeout!')
  end
end
io.stdout:write(('%d tests, %d failed\n'):format(ran, failed))
-- os.exit skips Neovim's own cleanup of its tempname dir (every H.tmpdir() lives there)
vim.fn.delete(vim.fn.fnamemodify(vim.fn.tempname(), ':h'), 'rf')
os.exit(failed == 0 and ran > 0 and 0 or 1)
