local H = require('helpers')

-- capture runs the health check with vim.health replaced and returns every report.
local function capture()
  local reports = {}
  local orig = vim.health
  vim.health = {
    start = function() end,
    ok = function(m) table.insert(reports, { 'ok', m }) end,
    warn = function(m) table.insert(reports, { 'warn', m }) end,
    error = function(m) table.insert(reports, { 'error', m }) end,
    info = function() end,
  }
  local ok, err = pcall(require('alder.health').check)
  vim.health = orig
  assert(ok, err)
  return reports
end

-- with_cmd runs fn with config.cmd set to a fake alder script (body is its shell text).
local function with_cmd(body, fn)
  local cfg = require('alder.config')
  local saved = cfg.options.cmd
  local path = H.tmpdir() .. '/alder'
  H.write(path, '#!/bin/sh\n' .. body .. '\n')
  vim.uv.fs_chmod(path, tonumber('755', 8))
  cfg.options.cmd = path
  local ok, err = pcall(fn)
  cfg.options.cmd = saved
  assert(ok, err)
end

local function errors_matching(reports, pat)
  local n = 0
  for _, r in ipairs(reports) do
    if r[1] == 'error' and r[2]:find(pat) then n = n + 1 end
  end
  return n
end

test('health: every check reports and none is an error on a working setup', function()
  H.ensure_parser()
  local reports = capture()
  assert(#reports >= 5, vim.inspect(reports))
  for _, r in ipairs(reports) do assert(r[1] ~= 'error', vim.inspect(reports)) end
end)

test('health: an alder whose help --json prints text is an error, though it exits 0', function()
  with_cmd('case "$1" in version) echo "alder 0.1.0";; *) echo "usage: alder <command>";; esac', function()
    local reports = capture()
    assert(errors_matching(reports, 'help %-%-json') == 1, vim.inspect(reports))
  end)
end)

test('health: JSON without a commands array is an error', function()
  with_cmd('case "$1" in version) echo "alder x";; *) echo "{}";; esac', function()
    assert(errors_matching(capture(), 'help %-%-json') == 1)
  end)
end)

test('health: a missing alder is an error', function()
  local cfg = require('alder.config')
  local saved = cfg.options.cmd
  cfg.options.cmd = 'alder-does-not-exist'
  local reports = capture()
  cfg.options.cmd = saved
  assert(errors_matching(reports, 'not on PATH') >= 1, vim.inspect(reports))
end)
