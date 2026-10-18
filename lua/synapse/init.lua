local M = {}
local session = require('synapse.session')
local ui = require('synapse.ui')
local markers = require('synapse.markers')

function M.setup(opts)
  local info = session.setup(opts)
  ui.setup()
  markers.setup(opts and opts.diagnostics)
  return info
end

M.browse = ui.browse
M.refresh = markers.refresh
M.compose = ui.compose
M.view = ui.view
M.info = session.info
M.threads = session.threads
M.edit = session.edit
M.delete = session.delete
M.clear = session.clear
M.saved_sessions = session.saved_sessions
M.resume = session.resume

function M.comment(args)
  return session.comment(args, 'human')
end

return M
