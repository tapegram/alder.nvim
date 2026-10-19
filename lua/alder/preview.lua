-- preview: the lines of the modal's preview pane from an alder/preview answer — the files it
-- would touch, a rule, the unified diff, the holes the result leaves — or the refusal. Pure.
local M = {}

local ACTION = { created = { '+ ', 'DiffAdd' }, removed = { '- ', 'DiffDelete' } }

function M.render(r)
  local lines, hls = {}, {}
  if not r then return lines, hls end
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { row = #lines, hl = hl } end
  end
  if r.error and r.error ~= '' then
    for _, l in ipairs(vim.split(r.error, '\n', { plain = true })) do add(l, 'DiagnosticError') end
    return lines, hls
  end
  for _, f in ipairs(r.files or {}) do
    local a = ACTION[f.action]
    if a then
      add(a[1] .. f.path, a[2])
    else
      add(('~ %s  +%d −%d'):format(f.path, f.added or 0, f.removed or 0), 'DiffChange')
    end
  end
  if #lines > 0 and ((r.diff and r.diff ~= '') or #(r.holes or {}) > 0) then add(string.rep('─', 40), 'Comment') end
  if r.diff and r.diff ~= '' then
    for _, l in ipairs(vim.split(r.diff, '\n', { plain = true })) do add(l) end
  end
  for _, h in ipairs(r.holes or {}) do add(('? %s : %s'):format(h.name, h.type), 'Comment') end
  return lines, hls
end

-- first_hunk is the row of the first `@@` line (the first change), else 1.
function M.first_hunk(lines)
  for i, l in ipairs(lines) do
    if vim.startswith(l, '@@') then return i end
  end
  return 1
end

return M
