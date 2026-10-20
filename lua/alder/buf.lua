-- buf reads two facts from an .alder buffer: its module name and the test at the cursor.
-- Through tree-sitter when the buffer has a parser, else by regex on the lines.
local M = {}

local function parser(bufnr)
  local ok, p = pcall(vim.treesitter.get_parser, bufnr, 'alder', { error = false })
  if ok and p then return p end
end

local function root_node(bufnr)
  local p = parser(bufnr)
  if not p then return nil end
  local trees = p:parse()
  return trees and trees[1] and trees[1]:root()
end

-- module_name is the (dotted, for a nested module: `Todos.Index`) name the buffer's `module`
-- line declares, or nil.
function M.module_name(bufnr)
  local root = root_node(bufnr)
  if root then
    for node in root:iter_children() do
      if node:type() == 'module_decl' then
        local name = node:field('name')[1]
        if name then return vim.treesitter.get_node_text(name, bufnr) end
      end
    end
  end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local name = l:match('^module%s+([%w_%.]+)')
    if name then return name end
  end
  return nil
end

-- test_at is the name of the nearest `test "name"` declaration starting at or above row
-- (0-based), as written between its quotes (escapes untouched), or nil.
function M.test_at(bufnr, row)
  local root = root_node(bufnr)
  if root then
    local best, best_row
    for node in root:iter_children() do
      local r = node:range()
      if node:type() == 'test_decl' and r <= row and (not best_row or r > best_row) then
        best, best_row = node, r
      end
    end
    if best then
      local s = best:field('name')[1]
      if s then return (vim.treesitter.get_node_text(s, bufnr):gsub('^"', ''):gsub('"$', '')) end
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
  for i = #lines, 1, -1 do
    local name = lines[i]:match('^test%s+"(.*)"%s*=')
    if name then return name end
  end
  return nil
end

return M
