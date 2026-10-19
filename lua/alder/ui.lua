-- ui: the look every alder float shares, lifted from durandal.nvim's util.lua — the centred
-- modal's options, rounded panes titled top-left — plus the nui.nvim gate and `plain`.
local M = {}

-- The large centred modal (the generator's): its layout options, and whether the editor is too
-- narrow for panes side by side.
M.modal = { relative = 'editor', position = '50%', size = { width = '80%', height = '80%' } }
function M.narrow() return vim.o.columns < 100 end

M.MISSING = 'alder: install nui.nvim for the generator UI'

-- has_nui reports whether nui.nvim loads; every float-opening entry point checks it first.
function M.has_nui()
  local ok = pcall(require, 'nui.popup')
  return ok
end

-- pane is a pane of such a modal: a rounded border, title (if any) top-left, no wrap. opts are
-- nui Popup options merged over these.
function M.pane(title, opts)
  local Popup = require('nui.popup')
  return Popup(vim.tbl_deep_extend('force', {
    border = { style = 'rounded', text = { top = title and (' ' .. title .. ' ') or nil, top_align = 'left' } },
    win_options = { wrap = false, cursorline = false, winhighlight = 'Normal:Normal,FloatBorder:FloatBorder' },
  }, opts or {}))
end

-- plain turns a server answer into plain Lua: its JSON nulls (vim.NIL, which is truthy) become
-- nil, at any depth.
function M.plain(v)
  if v == vim.NIL then return nil end
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = M.plain(x) end
  return setmetatable(out, getmetatable(v))
end

return M
