-- apply asks the server for a generator's plan (alder/plan) and applies it to buffers. Nothing
-- is written to disk, except a file the plan removes, after a confirm (R9). A created file is an
-- unsaved buffer marked b:alder_new, and its directory is made on the first :w (R10).
local root = require('alder.root')

local M = {}

-- named is the buffer named path (only a loaded one when loaded_only), or nil.
local function named(path, loaded_only)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if (not loaded_only or vim.api.nvim_buf_is_loaded(b)) and vim.api.nvim_buf_get_name(b) == path then return b end
  end
end

-- text_of is path's text as the user sees it: the loaded buffer's, else the file's, else nil.
function M.text_of(path)
  local b = named(path, true)
  if b then
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') .. (vim.bo[b].eol and '\n' or '')
  end
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- lines splits s into buffer lines; a final newline ends the last line rather than adding one.
function M.lines(s)
  local out = vim.split(s, '\n', { plain = true })
  if s:sub(-1) == '\n' then table.remove(out) end
  return out
end

-- null is JSON null (vim.NIL) as nil: a created file's `before`, a removed file's `after`.
local function null(v)
  if v == vim.NIL then return nil end
  return v
end

-- position is the LSP position of pos ({line, col} as nvim_win_get_cursor gives it), or of the
-- cursor of the window showing buf.
local function position(buf, pos)
  if not pos then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then win = vim.fn.bufwinid(buf) end
    pos = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
  end
  return { line = pos[1] - 1, character = pos[2] }
end

-- edit applies the checked plan's files in order and returns the buffers to open.
local function edit(r, files)
  local created, edited
  for _, f in ipairs(files) do
    local path = r .. '/' .. f.path
    local after = null(f.after)
    if after == nil then
      vim.fs.rm(path)
      local b = named(path)
      if b then vim.api.nvim_buf_delete(b, { force = true }) end
    elseif null(f.before) == nil then
      local b = vim.fn.bufadd(path)
      vim.fn.bufload(b)
      vim.bo[b].buflisted = true
      vim.api.nvim_buf_set_lines(b, 0, -1, false, M.lines(after))
      vim.b[b].alder_new = true
      if not created and f.path:match('%.alder$') then created = b end
    else
      local b = vim.fn.bufadd(path)
      vim.fn.bufload(b)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, M.lines(after))
      edited = edited or b
    end
  end
  return created, edited
end

-- run plans generator id with sets at pos in buf (default: the cursor of buf's window) and, when
-- nothing changed since planning, applies the plan to the buffers and calls on_done(plan).
function M.run(buf, id, sets, on_done, pos)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local r = root.for_buf(buf)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = position(buf, pos),
    id = id,
    sets = vim.empty_dict(),
  }
  for k, v in pairs(sets or {}) do params.sets[k] = v end
  require('alder.lsp').request(buf, 'alder/plan', params, function(plan)
    if null(plan.error) and plan.error ~= '' then
      vim.notify(plan.error, vim.log.levels.ERROR)
      require('alder.generate').refusal_list(r, { id }, null(plan.diagnostics))
      return
    end
    local files = null(plan.files) or {}
    local removed
    for _, f in ipairs(files) do
      if M.text_of(r .. '/' .. f.path) ~= null(f.before) then
        vim.notify('alder: ' .. f.path .. ' changed since planning; nothing applied', vim.log.levels.ERROR)
        return
      end
      if not removed and null(f.after) == nil then removed = f.path end
    end
    local function apply()
      local created, edited = edit(r, files)
      if created then
        vim.api.nvim_win_set_buf(0, created)
      elseif edited and edited ~= vim.api.nvim_get_current_buf() then
        vim.api.nvim_win_set_buf(0, edited)
      end
      local paths = {}
      for _, f in ipairs(files) do table.insert(paths, f.path) end
      vim.notify('alder: applied ' .. id .. ': ' .. table.concat(paths, ', '))
      if on_done then on_done(plan) end
    end
    if not removed then return apply() end
    vim.ui.select({ 'Yes', 'No' }, { prompt = 'Delete ' .. removed .. ' from disk? undo cannot restore it' }, function(choice)
      if choice == 'Yes' then apply() end
    end)
  end)
end

return M
