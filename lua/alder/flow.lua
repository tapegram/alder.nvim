-- flow is the plan-1 generator flow over vim.ui.select / vim.ui.input: ask the server for the
-- generator's form (alder/preview), ask for each invalid field, show the diff, and on <CR> apply
-- the plan to the buffers (apply.run). Every message is the server's own text.
local cli = require('alder.cli')
local generate = require('alder.generate')

local M = {}

local function request(...) return require('alder.lsp').request(...) end

-- cursor is the {line, col} of the window showing buf (the current window when it shows buf).
local function cursor(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then win = vim.fn.bufwinid(buf) end
  if win == -1 then return { 1, 0 }, nil end
  return vim.api.nvim_win_get_cursor(win), win
end

local function present(v)
  return v ~= nil and v ~= vim.NIL and v ~= ''
end

local function first_invalid(fields)
  for _, f in ipairs(fields or {}) do
    if not f.valid then return f end
  end
end

local function show(buf, win, id, sets, pos, preview)
  local lines = { '-- <CR> applies, q discards: ' .. id }
  vim.list_extend(lines, generate.render(preview))
  local sbuf = cli.scratch('alder://preview', lines, 'diff')
  vim.keymap.set('n', '<CR>', function()
    if vim.api.nvim_buf_is_valid(sbuf) then vim.api.nvim_buf_delete(sbuf, { force = true }) end
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    require('alder.apply').run(buf, id, sets, nil, pos)
  end, { buffer = sbuf, nowait = true })
end

local function step(buf, win, id, sets, pos)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = pos[1] - 1, character = pos[2] },
    id = id,
    sets = vim.empty_dict(),
  }
  for k, v in pairs(sets) do params.sets[k] = v end
  request(buf, 'alder/preview', params, function(preview)
    if not preview or preview == vim.NIL then return end
    if present(preview.error) then
      vim.notify(preview.error, vim.log.levels.ERROR)
      return
    end
    if preview.ready then return show(buf, win, id, sets, pos, preview) end
    local f = first_invalid(preview.fields)
    if not f then return end
    local function answer(value)
      if value == nil then return end
      local merged = vim.deepcopy(sets)
      merged[f.name] = value
      step(buf, win, id, merged, pos)
    end
    local prompt = f.name .. ' (' .. f.kind .. (present(f.why) and (', ' .. f.why) or '') .. '): '
    if f.choices and #f.choices > 0 then
      vim.ui.select(f.choices, { prompt = prompt }, answer)
    else
      vim.ui.input({ prompt = prompt, default = f.value }, answer)
    end
  end)
end

-- open runs generator id with the prefill sets, at the cursor of buf's window.
function M.open(buf, id, sets)
  if buf == 0 or buf == nil then buf = vim.api.nvim_get_current_buf() end
  local pos, win = cursor(buf)
  step(buf, win, id, vim.deepcopy(sets or {}), pos)
end

-- list requests alder/generators at the cursor of buf and calls cb(items).
function M.list(buf, cb)
  local pos = cursor(buf)
  request(buf, 'alder/generators', {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = pos[1] - 1, character = pos[2] },
  }, function(res)
    if res and res ~= vim.NIL and res.generators then cb(res.generators) end
  end)
end

-- pick (:AlderGenerate) opens generator id, or asks which one, the ones that apply here first.
function M.pick(buf, id)
  if buf == 0 or buf == nil then buf = vim.api.nvim_get_current_buf() end
  if id and id ~= '' then return M.open(buf, id, {}) end
  M.list(buf, function(items)
    vim.ui.select(items, {
      prompt = 'generator',
      format_item = function(g) return g.id .. (g.here and ('  (here: ' .. (g.why or '') .. ')') or '') end,
    }, function(g)
      if g then M.open(buf, g.id, g.sets) end
    end)
  end)
end

return M
