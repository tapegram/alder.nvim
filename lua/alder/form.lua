-- form: the generator's fields as the form pane shows them — one line per field whose text is
-- the value, a label and a note as virtual text, `[x] name` for a switch — and what to send
-- back. Pure: modal.lua owns the buffer.
local M = {}

M.NOTES = { here = 'from the cursor', default = 'default' }

local function is_bool(f) return f.kind == 'bool' end

function M.is_on(line) return vim.startswith(line, '[x]') end

-- toggle flips a switch line.
function M.toggle(line)
  if M.is_on(line) then return '[ ]' .. line:sub(4) end
  return '[x]' .. line:sub(4)
end

-- current is the text a field shows: what was typed, else the server's value.
local function current(f, typed)
  if typed[f.name] ~= nil then return typed[f.name] end
  return f.value or ''
end

-- lines are the form buffer's lines and, per row, the label (inline, blank for a switch), and
-- the note at the end of the line: `required` while empty, the server's why in error colour,
-- or where the value came from.
function M.lines(fields, typed)
  typed = typed or {}
  local lines, marks = {}, {}
  local width = 0
  for _, f in ipairs(fields) do width = math.max(width, #f.name) end
  for i, f in ipairs(fields) do
    local v = current(f, typed)
    if is_bool(f) then
      lines[i] = (v == 'true' and '[x] ' or '[ ] ') .. f.name
    else
      lines[i] = v
    end
    local note, hl
    if not is_bool(f) and v == '' and f.required then
      note, hl = 'required', 'Comment'
    elseif f.why and f.why ~= '' then
      note, hl = f.why, 'DiagnosticError'
    elseif f.source and M.NOTES[f.source] then
      note, hl = M.NOTES[f.source], 'Comment'
    end
    marks[i] = { row = i, label = is_bool(f) and '' or (f.name .. string.rep(' ', width - #f.name + 2)), note = note, note_hl = hl }
  end
  return lines, marks
end

-- sets is what the server gets: the preset (a code action's, or the item's here values) with
-- the typed text over it; an empty text drops the key, so the server falls back to the cursor.
-- The server's own values, defaults included, are never echoed back, so it re-decides each
-- request (a default switch can turn off when another field is set); a switch the user toggled
-- is sent as "true" or "false".
function M.sets(preset, typed)
  local out = {}
  for k, v in pairs(preset or {}) do
    if v ~= '' then out[k] = v end
  end
  for k, v in pairs(typed or {}) do
    if v ~= '' then out[k] = v else out[k] = nil end
  end
  return out
end

-- options are a choice field's choices matching the typed text (all for none).
function M.options(f, typed)
  local all = f.choices or {}
  if typed == nil or typed == '' then return vim.list_slice(all) end
  return vim.fn.matchfuzzy(all, typed)
end

-- first_invalid is the row of the first field the server marked invalid.
function M.first_invalid(fields)
  for i, f in ipairs(fields or {}) do
    if not f.valid then return i end
  end
end

-- ── Module names ─────────────────────────────────────────────────────────────

M.MODULE_EXAMPLE = 'Sites.Clarity.Index'

-- module_dirs are the folders under root/app as dotted prefixes (`Sites.`, `Sites.Clarity.`),
-- shallow first, then alphabetical. Only capitalised folders can hold modules.
function M.module_dirs(root)
  local out = {}
  local function walk(dir, prefix)
    for name, typ in vim.fs.dir(dir) do
      if typ == 'directory' and name:match('^%u') then
        out[#out + 1] = prefix .. name .. '.'
        walk(dir .. '/' .. name, prefix .. name .. '.')
      end
    end
  end
  walk(root .. '/app', '')
  table.sort(out, function(a, b)
    local da, db = select(2, a:gsub('%.', '')), select(2, b:gsub('%.', ''))
    if da ~= db then return da < db end
    return a < b
  end)
  return out
end

-- module_path is the file a module name is written to, relative to the app root.
function M.module_path(name) return 'app/' .. name:gsub('%.', '/') .. '.alder' end

-- module_help says where the name lands: the typed name (a trailing dot gets `Index`), else the example.
function M.module_help(text)
  local name = text or ''
  if name == '' then name = M.MODULE_EXAMPLE
  elseif name:sub(-1) == '.' then name = name .. 'Index' end
  return name .. ' → ' .. M.module_path(name)
end

-- module_suggest are the folder prefixes that complete text: those starting with it (fuzzy when
-- none do), not the text itself.
function M.module_suggest(dirs, text)
  if text == nil or text == '' then return vim.list_slice(dirs) end
  local out = {}
  for _, d in ipairs(dirs) do
    if d ~= text and vim.startswith(d, text) then out[#out + 1] = d end
  end
  if #out == 0 and text:sub(-1) ~= '.' then out = vim.fn.matchfuzzy(dirs, text) end
  return out
end

return M
