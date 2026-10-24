local M = {}

local QUERIES = { 'highlights', 'locals', 'indents', 'folds', 'injections', 'textobjects' }

local function version_at_least(v, min)
  local a = vim.version.parse(v or '')
  return a ~= nil and vim.version.ge(a, min)
end

function M.check()
  local h = vim.health
  h.start('alder')

  local cmd = require('alder.config').options.cmd
  if vim.fn.executable(cmd) == 1 then
    local v = vim.system({ cmd, 'version' }, { text = true }):wait()
    h.ok(vim.trim(v.stdout or '') ~= '' and vim.trim(v.stdout) or cmd)
    -- an old alder exits 0 and prints text for `help --json`: only a command tree counts
    local help = vim.system({ cmd, 'help', '--json' }, { text = true }):wait()
    local commands = require('alder.commands')
    local tree = help.code == 0 and commands.decode_tree(help.stdout)
    if tree then
      h.ok('`alder help --json` works (completion and :AlderGenerate)')
      if commands.tree_has_flag(tree, { 'repl' }, '--in') then
        h.info('`alder repl --in` is available (the REPL is deprecated: use scratch files)')
      else
        h.info('this alder has no `repl --in` (the REPL is deprecated: use scratch files)')
      end
    else
      h.error('`alder help --json` failed: this alder predates editor support; build a newer one')
    end
  else
    h.error(('`%s` is not on PATH'):format(cmd))
  end

  if not require('alder.config').options.lsp then
    h.warn('opts.lsp is false: CLI mode')
  else
    local status = require('alder.lsp').status()
    for _, s in ipairs(status) do
      if s.running then h.ok(('alder lsp running for `%s`'):format(s.root)) end
    end
    if #status == 0 then h.info('no alder lsp running (open an .alder file inside an app)') end
    for _, c in ipairs(vim.lsp.get_clients({ name = 'alder' })) do
      if not c:is_stopped() then
        local ex = c.server_capabilities and c.server_capabilities.experimental
        if ex and ex.alderScratch then
          h.ok(('alder lsp for `%s` supports scratch files (alder/scratch)'):format(c.root_dir))
        else
          h.warn(('alder lsp for `%s` has no scratch support: update alder, or :LspRestart'):format(c.root_dir))
        end
      end
    end
  end

  if require('alder.ui').has_nui() then
    h.ok('nui.nvim (the generator modal, <leader>ag)')
  else
    h.warn('nui.nvim is not installed: <leader>ag and :AlderGenerate need it (MunifTanjim/nui.nvim)')
  end

  if vim.fn.executable('tree-sitter') == 1 then
    local v = vim.system({ 'tree-sitter', '--version' }, { text = true }):wait()
    local version = (v.stdout or ''):match('(%d+%.%d+%.%d+)')
    if version_at_least(version, '0.26.1') then
      h.ok('tree-sitter ' .. version)
    else
      h.error('tree-sitter ' .. tostring(version) .. ': nvim-treesitter main needs 0.26.1 or newer (brew install tree-sitter-cli)')
    end
  else
    h.error('the tree-sitter CLI is not on PATH: brew install tree-sitter-cli')
  end

  if pcall(require, 'nvim-treesitter.config') then
    h.ok('nvim-treesitter (main)')
  else
    h.error('nvim-treesitter main is not installed (alder.nvim does not support the master branch)')
  end

  if pcall(vim.treesitter.language.add, 'alder') and vim.treesitter.language.add('alder') then
    h.ok('parser `alder` installed')
  else
    h.error('parser `alder` is not installed: run :TSInstall alder')
  end

  local missing = {}
  for _, name in ipairs(QUERIES) do
    local ok, q = pcall(vim.treesitter.query.get, 'alder', name)
    if not ok or not q then table.insert(missing, name .. (ok and '' or (' (' .. tostring(q) .. ')'))) end
  end
  if #missing == 0 then
    h.ok('queries installed: ' .. table.concat(QUERIES, ', '))
  else
    h.error('queries missing or broken: ' .. table.concat(missing, ', ') .. ' — run :TSUpdate alder')
  end
end

return M
