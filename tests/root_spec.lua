local H = require('helpers')
local root = require('alder.root')

test('root: nearest ancestor holding app/', function()
  local dir = H.tmpdir()
  H.write(dir .. '/app/Home.alder', 'module Home\n')
  H.write(dir .. '/app/Admin/Post/Index.alder', 'module Admin.Post.Index\n')
  assert(root.find(dir .. '/app/Home.alder') == dir)
  assert(root.find(dir .. '/app/Admin/Post/Index.alder') == dir)
end)

-- Review Focus 2: on a case-insensitive file system (macOS) a stat of app/app finds app/App,
-- so a module directory named App must not make app/ look like the root.
test('root: a module directory named App is not the app directory', function()
  local dir = H.tmpdir()
  H.write(dir .. '/app/App.alder', 'module App\n')
  H.write(dir .. '/app/App/Settings.alder', 'module App.Settings\n')
  assert(root.find(dir .. '/app/App/Settings.alder') == dir, root.find(dir .. '/app/App/Settings.alder'))
end)

test('root: none above a stray file', function()
  local dir = H.tmpdir()
  H.write(dir .. '/x/Stray.alder', 'module Stray\n')
  assert(root.find(dir .. '/x/Stray.alder') == nil)
end)
