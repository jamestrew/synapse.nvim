local M = {}
local markers_initialized = false

local function ui()
  local module = require('synapse.ui')
  module.setup()
  return module
end

function M.setup(opts)
  -- Session identity and discovery must be ready before an agent connects.
  local info = require('synapse.session').setup(opts)
  if opts and opts.diagnostics then
    vim.diagnostic.config(opts.diagnostics, vim.api.nvim_create_namespace('synapse'))
  end
  if markers_initialized then
    require('synapse.markers').refresh()
  end
  return info
end

function M.browse(author)
  return ui().browse(author)
end

function M.refresh()
  local markers = require('synapse.markers')
  if not markers_initialized then
    markers.setup()
    markers_initialized = true
  else
    markers.refresh()
  end
end

function M.compose(opts)
  return ui().compose(opts)
end

function M.view(id)
  return ui().view(id)
end

function M.info()
  return require('synapse.session').info()
end

function M.threads(author)
  return require('synapse.session').threads(author)
end

function M.edit(id, body)
  return require('synapse.session').edit(id, body)
end

function M.delete(id)
  return require('synapse.session').delete(id)
end

function M.clear(opts)
  return require('synapse.session').clear(opts)
end

function M.saved_sessions()
  return require('synapse.session').saved_sessions()
end

function M.resume(id, opts)
  return require('synapse.session').resume(id, opts)
end

function M.comment(args)
  return require('synapse.session').comment(args, 'human')
end

return M
