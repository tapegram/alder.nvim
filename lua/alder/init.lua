local M = {}

function M.setup(opts)
  require('alder.config').set(opts)
  require('alder.parser').register()
end

return M
