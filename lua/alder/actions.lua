-- actions is <leader>aa: the server's code actions for the cursor line, in one vim.ui.select.
-- Fixes apply their edit; a generator opens the flow. With nothing here, it names the first
-- line that has something.
local M = {}

local function request(...) return require('alder.lsp').request(...) end

local function uri_range(buf, s, e)
  return { textDocument = { uri = vim.uri_from_bufnr(buf) }, range = { start = s, ['end'] = e },
    context = { diagnostics = {} } }
end

-- first_line is the 1-based line of the first fix, or 1 when a generator applies (generators
-- are answered for range.start, which is the file's first line here).
local function first_line(actions)
  local line
  for _, a in ipairs(actions) do
    if a.edit then
      local d = a.diagnostics and a.diagnostics[1]
      if d then
        local l = d.range.start.line + 1
        line = line and math.min(line, l) or l
      end
    else
      return 1
    end
  end
  return line
end

local function nothing(buf)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local params = uri_range(buf, { line = 0, character = 0 }, { line = last, character = 0 })
  request(buf, 'textDocument/codeAction', params, function(actions)
    local n = first_line(actions or {})
    vim.notify('alder: nothing applies here; the first line that has something is ' .. (n or 'none'))
  end)
end

local function choose(buf, action)
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, 'utf-8')
  elseif action.data then
    require('alder.flow').open(buf, action.data.id, action.data.sets)
  end
end

function M.open()
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local p = { line = cur[1] - 1, character = cur[2] }
  request(buf, 'textDocument/codeAction', uri_range(buf, p, p), function(actions)
    if not actions or actions == vim.NIL or #actions == 0 then return nothing(buf) end
    local items = {}
    for _, a in ipairs(actions) do if a.edit then table.insert(items, a) end end
    for _, a in ipairs(actions) do if not a.edit then table.insert(items, a) end end
    vim.ui.select(items, { prompt = 'alder', format_item = function(a) return a.title end }, function(a)
      if a then choose(buf, a) end
    end)
  end)
end

return M
