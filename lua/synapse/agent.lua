local M = {}
local session = require('synapse.session')

---Supported live operations; Neovim RPC itself is trusted, not sandboxed.
---@return any
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

local function connect(socket)
  return vim.fn.sockconnect(socket:match('^.+:%d+$') and 'tcp' or 'pipe', socket, { rpc = true })
end

local function remote(socket, code, args)
  local channel = connect(socket)
  assert(channel > 0, 'synapse: cannot connect to session')
  local ok, result = pcall(vim.rpcrequest, channel, 'nvim_exec_lua', code, args)
  vim.fn.chanclose(channel)
  if not ok then
    error(result)
  end
  return result
end

local function probe(socket, timeout)
  -- rpcrequest blocks scheduled timers; bound a native remote-expr client instead.
  local result = vim
    .system({
      vim.v.progpath,
      '--headless',
      '-u',
      'NONE',
      '-i',
      'NONE',
      '--server',
      socket,
      '--remote-expr',
      [[json_encode(luaeval("require('synapse').info()"))]],
    }, { timeout = timeout })
    :wait()
  assert(result.code == 0, 'synapse: session did not answer its liveness probe')
  return vim.json.decode(assert(result.stdout))
end

---Probe advertisements rather than trusting leftover files after a crash.
function M.discover(opts)
  opts = opts or {}
  assert(type(opts.project_root) == 'string', 'synapse: project_root is required')
  local root = assert(vim.uv.fs_realpath(opts.project_root), 'synapse: project root does not exist')
  local dir = opts.discovery_dir or (vim.fn.stdpath('state') .. '/synapse/live')
  local timeout = opts.timeout_ms or 1000
  assert(
    type(timeout) == 'number' and timeout > 0 and timeout % 1 == 0,
    'synapse: timeout_ms must be a positive integer'
  )
  local result = {}
  for _, path in ipairs(require('synapse.storage').files(dir)) do
    local ok, info = pcall(function()
      local ad = require('synapse.storage').read(path)
      assert(ad.project_root == root and type(ad.socket) == 'string')
      assert(opts.session_id == nil or opts.session_id == ad.session_id)
      local live = probe(ad.socket, timeout)
      assert(
        live.session_id == ad.session_id and live.project_root == root and live.socket == ad.socket
      )
      return { session_id = live.session_id, project_root = root, socket = live.socket }
    end)
    if ok then
      result[#result + 1] = info
    end
  end
  return result
end

---Run from a separate Neovim process. Select exactly one live session, never broadcast.
function M.request(opts)
  assert(type(opts) == 'table', 'synapse: request must be a table')
  local matches = M.discover(opts)
  assert(#matches > 0, 'synapse: no matching live session')
  assert(#matches == 1, 'synapse: ambiguous project; select an explicit session_id')
  local target = assert(matches[1])
  return remote(target.socket, "return require('synapse.agent').dispatch(...)", {
    {
      session_id = target.session_id,
      project_root = target.project_root,
      op = opts.op,
      args = opts.args,
    },
  })
end

return M
