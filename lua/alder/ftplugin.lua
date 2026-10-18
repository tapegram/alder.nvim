local M = {}

-- include turns the module name under the cursor into a file name: Posts.Index -> Posts/Index.alder.
function M.include(name)
  return (name:gsub('%.', '/')) .. '.alder'
end

return M
