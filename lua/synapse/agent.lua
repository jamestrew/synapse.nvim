local M = {}
local session = require('synapse.session')

---Supported live operations; Neovim RPC itself is trusted, not sandboxed.
---@param request table Untrusted RPC payload; validate before dispatch.
---@return any The selected operation determines the response shape.
function M.dispatch(request)
  assert(type(request) == 'table', 'synapse: request must be a table')
  assert(request.session_id == session.info().session_id, 'synapse: session identity mismatch')
  assert(
    request.project_root == nil or request.project_root == session.info().project_root,
    'synapse: project identity mismatch'
  )
  local args = request.args or {}
  assert(type(args) == 'table', 'synapse: args must be a table')
  if request.op == 'threads' then
    return session.threads(args.author)
  elseif request.op == 'delete' then
    return session.delete(args.id)
  elseif request.op == 'clear' then
    return session.clear(args)
  elseif request.op == 'comment' then
    return session.comment(args, 'agent')
  end
  error('synapse: unsupported agent operation: ' .. tostring(request.op))
end

return M
