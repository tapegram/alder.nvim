local H = require('helpers')

test('filetype: .alder files are alder', function()
  assert(vim.filetype.match({ filename = 'x/app/Home.alder' }) == 'alder')
end)

test('parser: registered with location and queries from the alder repo', function()
  local info = require('alder.parser').install_info()
  assert(info.location == 'tree-sitter-alder', vim.inspect(info))
  assert(info.queries == 'tree-sitter-alder/queries/neovim', vim.inspect(info))
  assert(info.path == vim.fs.normalize(H.alder_repo()), vim.inspect(info))
end)

test('parser: without path it downloads tapegram/alder', function()
  local config = require('alder.config')
  local saved = config.options
  config.set({ revision = 'v9.9.9' })
  local info = require('alder.parser').install_info()
  config.options = saved
  assert(info.url == 'https://github.com/tapegram/alder' and info.revision == 'v9.9.9' and info.path == nil, vim.inspect(info))
end)

test('queries: all six compile against the installed parser', function()
  H.ensure_parser()
  for _, name in ipairs({ 'highlights', 'locals', 'indents', 'folds', 'injections', 'textobjects' }) do
    local ok, q = pcall(vim.treesitter.query.get, 'alder', name)
    assert(ok and q, name .. ': ' .. tostring(q))
  end
end)

test('highlights: captures at known positions', function()
  H.ensure_parser()
  local file = H.tmpdir() .. '/Demo.alder'
  H.write(file, 'module Demo\n\nview : Int -> Html Never\nview n = <p class="x">{n}</p>\n')
  vim.cmd.edit(file)
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].filetype == 'alder')
  vim.treesitter.start(buf, 'alder')
  vim.treesitter.get_parser(buf):parse()
  local function has(row, col, capture)
    for _, c in ipairs(vim.treesitter.get_captures_at_pos(buf, row, col)) do
      if c.capture == capture then return true end
    end
    local names = vim.tbl_map(function(c) return c.capture end, vim.treesitter.get_captures_at_pos(buf, row, col))
    error(('(%d,%d): want @%s, have %s'):format(row, col, capture, vim.inspect(names)))
  end
  has(0, 0, 'keyword.import')
  has(2, 0, 'function')
  has(2, 7, 'type')
  has(3, 10, 'tag')
  has(3, 12, 'tag.attribute')
  has(3, 18, 'string')
end)

test('ftplugin: comments, indentation and folds', function()
  H.ensure_parser()
  local file = H.tmpdir() .. '/Demo.alder'
  H.write(file, 'module Demo\n')
  vim.cmd.edit(file)
  assert(vim.bo.commentstring == '-- %s')
  assert(vim.bo.shiftwidth == 2 and vim.bo.expandtab)
  assert(vim.wo.foldmethod == 'expr' and vim.wo.foldexpr:find('treesitter'))
  assert(vim.bo.indentexpr:find('nvim%-treesitter'))
end)
