local preview = require('alder.preview')

test('preview: files, rule, diff and holes', function()
  local lines, hls = preview.render({
    files = { { path = 'app/Posts/Index.alder', action = 'edited', added = 3, removed = 1 }, { path = 'app/New.alder', action = 'created', added = 9, removed = 0 } },
    diff = '--- a/app/Posts/Index.alder\n+++ b/app/Posts/Index.alder\n@@ -1 +1 @@\n-x\n+y',
    holes = { { name = 'delete', type = 'Task Nav' } },
  })
  assert(lines[1] == '~ app/Posts/Index.alder  +3 −1' and hls[1].hl == 'DiffChange', vim.inspect({ lines, hls }))
  assert(lines[2] == '+ app/New.alder' and hls[2].hl == 'DiffAdd', vim.inspect(lines))
  assert(lines[3] == string.rep('─', 40) and hls[3].hl == 'Comment')
  assert(lines[4] == '--- a/app/Posts/Index.alder' and lines[8] == '+y', vim.inspect(lines))
  assert(lines[9] == '? delete : Task Nav' and hls[#hls].row == 9 and hls[#hls].hl == 'Comment', vim.inspect({ lines, hls }))
  assert(preview.first_hunk(lines) == 6)
end)

test('preview: an error replaces the diff; a removal is marked', function()
  local lines, hls = preview.render({ error = 'module `About` exists (`app/About.alder`): a generator never overwrites a file', files = {} })
  assert(lines[1]:find('module `About` exists', 1, true) and hls[1].hl == 'DiagnosticError', vim.inspect({ lines, hls }))
  lines, hls = preview.render({ files = { { path = 'app/Old.alder', action = 'removed', added = 0, removed = 12 } }, diff = '' })
  assert(lines[1] == '- app/Old.alder' and hls[1].hl == 'DiffDelete', vim.inspect(lines))
  assert(preview.first_hunk(lines) == 1)
end)

test('preview: nothing yet', function()
  local lines, hls = preview.render(nil)
  assert(#lines == 0 and #hls == 0)
end)
