local H = {}

function H.alder_repo()
  return os.getenv('ALDER_REPO') or vim.fn.expand('~/projects/alder')
end

local installed = false
-- ensure_parser compiles and installs the alder parser and links its queries from ALDER_REPO.
function H.ensure_parser()
  if installed then return end
  local ok = require('nvim-treesitter').install({ 'alder' }, { force = true }):wait(300000)
  assert(ok, 'installing the alder parser failed (see :messages / nvim-treesitter log)')
  installed = true
end

function H.tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return vim.uv.fs_realpath(d)
end

function H.wait(ms, cond)
  return vim.wait(ms, cond, 20)
end

function H.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

function H.read(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- capture_notify records vim.notify messages until restore() is called.
function H.capture_notify()
  local messages, orig = {}, vim.notify
  vim.notify = function(msg, level) table.insert(messages, { msg = msg, level = level }) end
  return messages, function() vim.notify = orig end
end

-- float_text is the text of every floating window's buffer, newline-joined.
function H.float_text()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      vim.list_extend(out, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false))
    end
  end
  return table.concat(out, '\n')
end

-- new_app runs `alder new <dir>/demo` and returns the app root.
function H.new_app()
  local root = H.tmpdir() .. '/demo'
  local r = vim.system({ 'alder', 'new', root }, { text = true }):wait()
  assert(r.code == 0, 'alder new failed: ' .. (r.stderr or ''))
  return root
end

-- copy_tree copies a directory recursively (fixtures from the alder repo's testdata).
function H.copy_tree(src, dst)
  vim.fn.mkdir(dst, 'p')
  for name, typ in vim.fs.dir(src) do
    local s, d = src .. '/' .. name, dst .. '/' .. name
    if typ == 'directory' then H.copy_tree(s, d) else vim.uv.fs_copyfile(s, d) end
  end
end

return H
