local M = {}

local function opts() return require('alder.config').options end

local warned = false
-- available reports whether the alder binary is on PATH, and says how to get it once.
function M.available()
  if vim.fn.executable(opts().cmd) == 1 then return true end
  if not warned then
    warned = true
    vim.notify(('alder: `%s` is not on PATH. Build it from a checkout: go build -o ~/bin/alder ./cmd/alder'):format(opts().cmd),
      vim.log.levels.ERROR)
  end
  return false
end

-- decode returns every JSON object printed one per line on stdout (JSONL, or one object).
function M.decode(stdout)
  local out = {}
  for line in vim.gsplit(stdout or '', '\n', { plain = true }) do
    if line:match('^%s*{') then
      local ok, v = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(v) == 'table' then table.insert(out, v) end
    end
  end
  return out
end

-- run starts `alder <args>` and calls on_done(res) on the main loop.
function M.run(args, o, on_done)
  if not M.available() then return nil end
  local argv = { opts().cmd }
  vim.list_extend(argv, args)
  return vim.system(argv, { cwd = o.cwd, stdin = o.stdin, text = true }, function(r)
    local objects = M.decode(r.stdout)
    local res = { code = r.code, signal = r.signal, stdout = r.stdout or '', stderr = r.stderr or '',
      objects = objects, json = objects[1] }
    vim.schedule(function() on_done(res) end)
  end)
end

-- buf_named returns the buffer with exactly this name, or nil.
function M.buf_named(name)
  local b = vim.fn.bufnr('^' .. vim.fn.escape(name, '\\.[]*~$^') .. '$')
  return b ~= -1 and b or nil
end

-- scratch opens a bottom split on a new scratch buffer holding lines and returns the buffer.
function M.scratch(name, lines, filetype)
  -- a buffer already holding the name would make set_name fail: wipe it so the new one gets the name
  local old = M.buf_named(name)
  if old then pcall(vim.api.nvim_buf_delete, old, { force = true }) end
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if filetype then vim.bo[buf].filetype = filetype end
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true })
  return buf
end

-- report shows a failed run without rewording it: a JSON `error` as is, a usage or internal
-- failure (exit 2) with its stderr in a split, anything else as its stderr.
function M.report(args, res, o)
  o = o or {}
  if res.json and res.json.error then
    vim.notify(res.json.error, vim.log.levels.ERROR)
  elseif res.code == 2 and o.bug_on_2 ~= false then
    local v = vim.system({ opts().cmd, 'version' }, { text = true }):wait()
    local lines = { 'This may be a compiler bug; `alder version` and the command are in this buffer.', '',
      '$ alder ' .. table.concat(args, ' '), '' }
    vim.list_extend(lines, vim.split(vim.trim(res.stderr ~= '' and res.stderr or res.stdout), '\n', { plain = true }))
    vim.list_extend(lines, { '', '$ alder version', vim.trim(v.stdout or '') })
    M.scratch('alder://error', lines)
  else
    local text = vim.trim(res.stderr ~= '' and res.stderr or res.stdout)
    vim.notify(text ~= '' and text or ('alder ' .. args[1] .. ' exited ' .. res.code), vim.log.levels.ERROR)
  end
end

return M
