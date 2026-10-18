local M = {}

-- has_app reports whether dir has an entry named exactly `app` that is a directory. It reads
-- the listing instead of stat-ing dir/app: on a case-insensitive file system that stat
-- succeeds for a module directory named App.
local function has_app(dir)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return false end
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then return false end
    if name == 'app' then
      return typ == 'directory' or vim.fn.isdirectory(dir .. '/app') == 1
    end
  end
end

-- find returns the app root for a file or directory: its nearest ancestor holding app/.
function M.find(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  dir = dir:gsub('/$', '')
  while dir and dir ~= '' do
    if has_app(dir) then return dir end
    local parent = vim.fs.dirname(dir)
    if parent == dir then return nil end
    dir = parent
  end
  return nil
end

function M.for_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == '' or name:match('^%a+://') then return M.find(vim.fn.getcwd()) end
  return M.find(name)
end

return M
