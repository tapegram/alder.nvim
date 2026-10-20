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

local function entries(n) return ('%d entr%s'):format(n, n == 1 and 'y' or 'ies') end

-- put writes text to the REPL's job and reports whether it could: a job that has gone makes
-- chansend raise E900, which is caught here and said as a notice by the caller.
local function put(s, text)
  local ok, n = pcall(vim.fn.chansend, s.job, text)
  return ok and n > 0
end

local function flush(s)
  local queue = s.queue
  s.queue = {}
  for i, text in ipairs(queue) do
    if not put(s, text) then
      vim.notify('alder repl: the REPL has exited; ' .. entries(#queue - i + 1) .. ' not sent', vim.log.levels.WARN)
      return
    end
  end
end

-- banner is the end of the line the REPL prints once it reads input:
-- `alder repl: <app>, in <M> (:help for the commands, :quit to leave)`, without `, in <M>` in
-- app scope. Its startup errors (`alder repl: no module …`, `alder repl: the app has errors; …`)
-- share the prefix, not this.
function M.banner(module)
  return (module and (', in ' .. module) or '') .. ' (:help for the commands'
end

-- show puts the session's buffer in a bottom split without taking the focus.
local function show(s)
  local cur = vim.api.nvim_get_current_win()
  vim.cmd('botright sbuffer ' .. s.buf)
  vim.cmd('stopinsert')
  vim.api.nvim_set_current_win(cur)
end

-- open starts the app's REPL in a bottom split (speaking as module, when given) or focuses
-- the running one; the module of a running REPL is not changed (`:in` inside it does that).
-- Text sent before the REPL prints its banner is queued and flushed as the banner arrives
-- (a chansend that early would be lost); a REPL that exits before it says the text was not sent.
function M.open(app_root, module)
  local key = root.real(app_root)
  local s = M.sessions[key]
  if alive(s) then
    local w = win_of(s.buf)
    if w then vim.api.nvim_set_current_win(w) else vim.cmd('botright sbuffer ' .. s.buf) end
    return s
  end
  if not require('alder.cli').available() then return nil end
  local banner = M.banner(module)
  vim.cmd('botright new')
  local win = vim.api.nvim_get_current_win()
  s = { ready = false, queue = {}, seen = '' }
  s.buf = vim.api.nvim_get_current_buf()
  local ok, job = pcall(vim.fn.jobstart, M.argv(app_root, module), {
    term = true,
    cwd = app_root,
    on_stdout = function(_, data)
      if s.ready then return end
      -- the banner may arrive split across chunks: look at everything seen so far
      s.seen = s.seen .. table.concat(data or {}, '\n')
      if s.seen:find(banner, 1, true) then
        s.ready, s.seen = true, nil
        flush(s) -- here, not scheduled: a send after ready must not overtake the queue
      end
    end,
    on_exit = function()
      if M.sessions[key] == s then M.sessions[key] = nil end
      if not s.ready and #s.queue > 0 then
        local n = #s.queue
        s.queue = {}
        vim.notify('alder repl: the REPL exited before it was ready; ' .. entries(n) .. ' not sent', vim.log.levels.WARN)
      end
    end,
  })
  if not ok or job <= 0 then
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(s.buf) then pcall(vim.api.nvim_buf_delete, s.buf, { force = true }) end
    vim.notify('alder repl: could not start `' .. table.concat(M.argv(app_root, module), ' ') .. '`', vim.log.levels.ERROR)
    return nil
  end
  s.job = job
  M.sessions[key] = s
  vim.cmd('startinsert')
  return s
end

-- send gives text to the app's REPL. With none running it starts one (speaking as module,
-- when given) without taking the focus; text sent before the banner waits for it. A running
-- REPL whose window was closed is shown again (without the focus), so the result is seen.
function M.send(app_root, text, module)
  local s = M.sessions[root.real(app_root)]
  if alive(s) then
    if not win_of(s.buf) then show(s) end
  else
    local cur = vim.api.nvim_get_current_win()
    s = M.open(app_root, module)
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(cur)
    if not s then return end
  end
  if not s.ready or #s.queue > 0 then return table.insert(s.queue, text) end
  if not put(s, text) then
    vim.notify('alder repl: the REPL has exited; not sent: ' .. vim.trim(text), vim.log.levels.WARN)
  end
end

-- module_for_buf is the module a REPL for buf speaks as: the buffer's `module` name (dotted
-- for a nested one) in an .alder buffer, else nil (app scope). An alder without `repl --in`
-- gets nil too, with a warning; a missing alder gets the module (open says it is missing).
function M.module_for_buf(buf)
  local module = vim.bo[buf].filetype == 'alder' and require('alder.buf').module_name(buf) or nil
  -- with no binary at all, say nothing here: open reports the missing binary
  local present = vim.fn.executable(require('alder.config').options.cmd) == 1
  if module and present and not require('alder.commands').has_flag({ 'repl' }, '--in') then
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
