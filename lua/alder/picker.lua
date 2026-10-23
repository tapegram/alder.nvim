-- picker: the generator list of the modal — the fuzzy filter over the server's items and the
-- lines of the list pane. Pure: no buffers here (modal.lua renders).
local M = {}

-- filter is the items whose `id summary` fuzzy-match query, best first; a copy of all of them,
-- in the server's order (here first), for an empty query.
-- text(item), when given, is the string to match instead (the routes picker matches paths).
function M.filter(items, query, text)
  if query == nil or query == '' then return vim.list_slice(items) end
  text = text or function(it) return it.id .. ' ' .. (it.summary or '') end
  local keyed = {}
  for _, it in ipairs(items) do keyed[#keyed + 1] = { text = text(it), item = it } end
  local out = {}
  for _, k in ipairs(vim.fn.matchfuzzy(keyed, query, { key = 'text' })) do out[#out + 1] = k.item end
  return out
end

-- lines renders items: `id`, two spaces past the longest id, the summary. marks are the
-- summaries' {row, col, hl}; headings (when grouped) go above the first here item and the
-- first other one as virtual lines.
function M.lines(items, grouped)
  local lines, marks, headings = {}, {}, {}
  local width = 0
  for _, it in ipairs(items) do width = math.max(width, #it.id) end
  local seen_here, seen_rest = false, false
  for i, it in ipairs(items) do
    local pad = string.rep(' ', width - #it.id + 2)
    lines[i] = it.id .. pad .. (it.summary or '')
    marks[i] = { row = i, col = #it.id + #pad, hl = 'Comment' }
    if grouped then
      if it.here and not seen_here then
        headings[#headings + 1] = { row = i, text = '── here ──' }
        seen_here = true
      elseif not it.here and not seen_rest then
        headings[#headings + 1] = { row = i, text = '── all ──' }
        seen_rest = true
      end
    end
  end
  return lines, marks, headings
end

return M
