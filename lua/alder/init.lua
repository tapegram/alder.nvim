local M = {}

function M.setup(opts)
  require('alder.config').set(opts)
  require('alder.parser').register()
  require('alder.keys').attach_global()
end

return M
