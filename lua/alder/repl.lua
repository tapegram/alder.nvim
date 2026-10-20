-- repl runs `alder repl` in a terminal split, one per app, and sends text to it.
local root = require('alder.root')

local M = {}

M.sessions = {} -- real app root → { job, buf, ready, queue }

-- argv is the command line: `alder repl --in <module>` inside a module, `alder repl` outside.
function M.argv(_, module)
  local argv = { require('alder.config').options.cmd, 'repl' }
  if module then vim.list_extend(argv, { '--in', module }) end
  return argv
end

-- join makes one REPL entry of lines: the common indent stripped, each line but the last
-- ended by the REPL's ` \` continuation, a newline at the end.
function M.join(lines)
  local indent
  for _, l in ipairs(lines) do
    if l:match('%S') then
      local n = #l:match('^%s*')
      indent = indent and math.min(indent, n) or n
    end
  end
  local out = {}
  for _, l in ipairs(lines) do table.insert(out, l:sub((indent or 0) + 1)) end
  return table.concat(out, ' \\\n') .. '\n'
end

local function alive(s)
  return s and s.job and vim.fn.jobwait({ s.job }, 0)[1] == -1 and vim.api.nvim_buf_is_valid(s.buf)
end

local function win_of(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then return w end
  end
end

local function flush(s)
  for _, text in ipairs(s.queue) do vim.fn.chansend(s.job, text) end
  s.queue = {}
end

local BANNER = 'alder repl:'

-- open starts the app's REPL in a bottom split (speaking as module, when given) or focuses
-- the running one; the module of a running REPL is not changed (`:in` inside it does that).
-- Text sent before the REPL prints its banner is queued and flushed once the banner arrives:
-- a chansend that early would be lost.
function M.open(app_root, module)
  local key = root.real(app_root)
  local s = M.sessions[key]
  if alive(s) then
    local w = win_of(s.buf)
    if w then vim.api.nvim_set_current_win(w) else vim.cmd('botright sbuffer ' .. s.buf) end
    return s
  end
  vim.cmd('botright new')
  s = { ready = false, queue = {}, seen = '' }
  s.buf = vim.api.nvim_get_current_buf()
  s.job = vim.fn.jobstart(M.argv(app_root, module), {
    term = true,
    cwd = app_root,
    on_stdout = function(_, data)
      if s.ready then return end
      -- the banner may arrive split across chunks: look at everything seen so far
      s.seen = s.seen .. table.concat(data or {}, '\n')
      if s.seen:find(BANNER, 1, true) then
        s.ready, s.seen = true, nil
        vim.schedule(function() flush(s) end)
      end
    end,
    on_exit = function() if M.sessions[key] == s then M.sessions[key] = nil end end,
  })
  if s.job <= 0 then
    vim.notify('alder repl: could not start `' .. table.concat(M.argv(app_root, module), ' ') .. '`', vim.log.levels.ERROR)
    return nil
  end
  M.sessions[key] = s
  vim.cmd('startinsert')
  return s
end

-- send gives text to the app's REPL. With none running it starts one (speaking as module,
-- when given) without taking the focus; text sent before the banner waits for it.
function M.send(app_root, text, module)
  local s = M.sessions[root.real(app_root)]
  if not alive(s) then
    local cur = vim.api.nvim_get_current_win()
    s = M.open(app_root, module)
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(cur)
    if not s then return end
  end
  if s.ready then vim.fn.chansend(s.job, text) else table.insert(s.queue, text) end
end

-- module_for_buf is the module a REPL for buf speaks as: the buffer's `module` name (dotted
-- for a nested one) in an .alder buffer, else nil (app scope). An alder without `repl --in`
-- gets nil too, with a warning.
function M.module_for_buf(buf)
  local module = vim.bo[buf].filetype == 'alder' and require('alder.buf').module_name(buf) or nil
  if module and not require('alder.commands').has_flag({ 'repl' }, '--in') then
    vim.notify('alder repl: this alder has no --in; update it (opening in app scope)', vim.log.levels.WARN)
    return nil
  end
  return module
end

-- for_current opens the REPL of the current buffer's app, in its module.
function M.for_current()
  local r = root.require_for_buf(0)
  if r then M.open(r, M.module_for_buf(vim.api.nvim_get_current_buf())) end
end

-- send_current sends the current line ('n') or the visual selection ('x') to the REPL of the
-- current buffer's app, starting one in the buffer's module when none runs.
function M.send_current(mode)
  local r = root.require_for_buf(0)
  if not r then return end
  local lines
  if mode == 'x' then
    vim.cmd('normal! \27') -- leave visual mode so the marks are set
    local a, b = vim.fn.line("'<"), vim.fn.line("'>")
    lines = vim.api.nvim_buf_get_lines(0, a - 1, b, false)
  else
    lines = { vim.api.nvim_get_current_line() }
  end
  local s = M.sessions[root.real(r)]
  local module = not alive(s) and M.module_for_buf(vim.api.nvim_get_current_buf()) or nil
  M.send(r, M.join(lines), module)
end

return M
