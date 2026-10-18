local M = {}
local storage = require('synapse.storage')

---@alias synapse.Author 'human'|'agent'

---@class synapse.Anchor
---@field file string Relative to the stable project root.
---@field line integer 1-based, inclusive.
---@field end_line integer 1-based, inclusive.

---@class synapse.Comment
---@field id string
---@field author synapse.Author
---@field body string
---@field anchor synapse.Anchor
---@field parent_id? string

---@class synapse.Thread
---@field id string
---@field anchor synapse.Anchor
---@field comments synapse.Comment[]

---@class synapse.State
---@field version integer
---@field session_id string
---@field project_root string
---@field next_id integer
---@field comments synapse.Comment[]

---@class synapse.SetupOpts
---@field root? string
---@field discovery_dir? string
---@field storage_dir? string
---@field diagnostics? vim.diagnostic.Opts

---@class synapse.Info
---@field session_id string
---@field generation integer
---@field project_root string
---@field socket string
---@field discovery_dir string
---@field storage_dir string

---@class synapse.CommentInput
---@field body string
---@field file? string
---@field line? integer
---@field end_line? integer
---@field parent_id? string

---@class synapse.ComposeOpts
---@field file? string
---@field line? integer
---@field end_line? integer
---@field parent_id? string
---@field id? string

---@class synapse.ClearOpts
---@field confirm boolean
---@field include_human? boolean

---@class synapse.ResumeOpts
---@field confirm? boolean

---@class synapse.SavedSession
---@field session_id string
---@field project_root string
---@field comment_count integer

---@type synapse.State?
local state
local generation = 0
---@type { discovery_dir: string, storage_dir: string, socket?: string }
local config

---@return synapse.State
local function current()
  assert(state, 'synapse: call setup() first')
  return state
end

---@param value any
---@return boolean
local function nonblank(value)
  return type(value) == 'string' and value:find('%S') ~= nil
end

---@param value any
---@return boolean
local function integer(value)
  return type(value) == 'number' and value >= 1 and value % 1 == 0
end

---@param path string
---@return string
local function canonical(path)
  return vim.uv.fs_realpath(path)
    or vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ':p'))):gsub('/$', '')
end

---@param opts? synapse.SetupOpts
---@return synapse.Info
function M.setup(opts)
  if state then
    return M.info()
  end
  opts = opts or {}
  assert(type(opts) == 'table', 'synapse: setup options must be a table')
  local root = opts.root
  assert(root == nil or nonblank(root), 'synapse: root must be a nonblank path')
  if not root and vim.fn.executable('git') == 1 then
    local lines =
      vim.fn.systemlist({ 'git', '-C', vim.fn.getcwd(), 'rev-parse', '--show-toplevel' })
    root = vim.v.shell_error == 0 and lines[1] or vim.fn.getcwd()
  end
  root = canonical(root or vim.fn.getcwd())
  assert(vim.fn.isdirectory(root) == 1, 'synapse: project root must be a directory')
  assert(
    opts.discovery_dir == nil or nonblank(opts.discovery_dir),
    'synapse: invalid discovery directory'
  )
  assert(
    opts.storage_dir == nil or nonblank(opts.storage_dir),
    'synapse: invalid storage directory'
  )
  config = {
    discovery_dir = canonical(opts.discovery_dir or (vim.fn.stdpath('state') .. '/synapse/live')),
    storage_dir = canonical(opts.storage_dir or (vim.fn.stdpath('data') .. '/synapse/sessions')),
  }
  assert(
    config.discovery_dir ~= config.storage_dir,
    'synapse: discovery and saved sessions need separate directories'
  )
  state = {
    version = 1,
    session_id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. ':' .. vim.fn.getpid()):sub(1, 24),
    project_root = root,
    next_id = 1,
    comments = {},
  }
  config.socket = vim.v.servername ~= '' and vim.v.servername or vim.fn.serverstart()
  local advertisement = config.discovery_dir .. '/' .. state.session_id .. '.json'
  local ok, err = pcall(storage.write, advertisement, {
    version = 1,
    project_root = root,
    session_id = state.session_id,
    socket = config.socket,
  })
  if not ok then
    state = nil
    error(err)
  end
  vim.api.nvim_create_autocmd('VimLeavePre', {
    once = true,
    callback = function()
      vim.uv.fs_unlink(advertisement)
    end,
  })
  return M.info()
end

---@return synapse.Info
function M.info()
  local s = current()
  return {
    session_id = s.session_id,
    generation = generation,
    project_root = s.project_root,
    socket = assert(config.socket),
    discovery_dir = config.discovery_dir,
    storage_dir = config.storage_dir,
  }
end

---@param args synapse.CommentInput
---@return synapse.Anchor
local function anchor(args)
  local s = current()
  assert(type(args.file) == 'string' and nonblank(args.file), 'synapse: file is required')
  local absolute = canonical(vim.fs.joinpath(s.project_root, args.file))
  if args.file:sub(1, 1) == '/' then
    absolute = canonical(args.file)
  end
  local prefix = s.project_root == '/' and '/' or (s.project_root .. '/')
  assert(absolute:sub(1, #prefix) == prefix, 'synapse: file must be inside the project root')
  local buf = vim.fn.bufnr(absolute)
  local count
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    assert(vim.bo[buf].buftype == '', 'synapse: anchor must be a working file')
    count = vim.api.nvim_buf_line_count(buf)
  else
    assert(vim.fn.filereadable(absolute) == 1, 'synapse: anchor must be a working file')
    count = math.max(1, #vim.fn.readfile(absolute))
  end
  local last = args.end_line or args.line
  assert(
    type(args.line) == 'number'
      and integer(args.line)
      and type(last) == 'number'
      and integer(last)
      and last >= args.line
      and last <= count,
    'synapse: invalid line range'
  )
  return { file = absolute:sub(#prefix + 1), line = args.line, end_line = last }
end

---@param s synapse.State
---@param id string
---@return synapse.Comment
local function find(s, id)
  for _, c in ipairs(s.comments) do
    if c.id == id then
      return c
    end
  end
  error('synapse: unknown comment: ' .. tostring(id))
end

---@param next_state synapse.State
---@param resumed? boolean
---@return nil
local function commit(next_state, resumed)
  storage.write(config.storage_dir .. '/' .. next_state.session_id .. '.json', next_state)
  state = next_state
  if resumed then
    generation = generation + 1
  end
  local ok, err =
    pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'SynapseChanged', modeline = false })
  if not ok then
    vim.notify('synapse: saved, but display refresh failed: ' .. tostring(err), vim.log.levels.WARN)
  end
end

---@param args synapse.CommentInput
---@param author synapse.Author
---@return synapse.Comment
function M.comment(args, author)
  assert(type(args) == 'table', 'synapse: comment arguments must be a table')
  for key in pairs(args) do
    assert(
      vim.tbl_contains({ 'file', 'line', 'end_line', 'body', 'parent_id' }, key),
      'synapse: unknown comment field: ' .. tostring(key)
    )
  end
  assert(nonblank(args.body), 'synapse: comment body must not be blank')
  ---@diagnostic disable-next-line: unnecessary-assert -- Keep validation for untyped/RPC callers.
  assert(author == 'human' or author == 'agent', 'synapse: invalid author')
  local s = vim.deepcopy(current())
  ---@type synapse.Anchor
  local location
  if args.parent_id ~= nil then
    assert(
      args.file == nil and args.line == nil and args.end_line == nil,
      'synapse: replies inherit their parent anchor'
    )
    location = vim.deepcopy(find(s, args.parent_id).anchor)
  else
    location = anchor(args)
  end
  local c = {
    id = 'c' .. s.next_id,
    author = author,
    body = args.body,
    anchor = location,
    parent_id = args.parent_id,
  }
  s.next_id = s.next_id + 1
  s.comments[#s.comments + 1] = c
  commit(s)
  return vim.deepcopy(c)
end

---@param id string
---@param body string
---@return synapse.Comment
function M.edit(id, body)
  assert(nonblank(body), 'synapse: comment body must not be blank')
  local s = vim.deepcopy(current())
  local c = find(s, id)
  assert(c.author == 'human', 'synapse: only human comments can be edited')
  c.body = body
  commit(s)
  return vim.deepcopy(c)
end

---@param id string
---@return true
function M.delete(id)
  local s = vim.deepcopy(current())
  find(s, id)
  for _, c in ipairs(s.comments) do
    assert(c.parent_id ~= id, 'synapse: cannot delete a comment with replies')
  end
  s.comments = vim.tbl_filter(function(c)
    return c.id ~= id
  end, s.comments)
  commit(s)
  return true
end

---@param opts synapse.ClearOpts
---@return integer
function M.clear(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'synapse: clear options must be a table')
  for key in pairs(opts) do
    ---@diagnostic disable-next-line: unnecessary-assert -- Keep validation for untyped/RPC callers.
    assert(
      key == 'confirm' or key == 'include_human',
      'synapse: unknown clear option: ' .. tostring(key)
    )
  end
  assert(opts.confirm == true, 'synapse: clearing requires confirm=true')
  assert(
    opts.include_human == nil or type(opts.include_human) == 'boolean',
    'synapse: include_human must be boolean'
  )
  local s = vim.deepcopy(current())
  local before = #s.comments
  s.comments = vim.tbl_filter(function(c)
    return not opts.include_human and c.author == 'human'
  end, s.comments)
  local kept = {}
  for _, c in ipairs(s.comments) do
    kept[c.id] = true
  end
  for _, c in ipairs(s.comments) do
    assert(
      not c.parent_id or kept[c.parent_id],
      'synapse: clearing would leave dangling replies; include humans explicitly to clear all'
    )
  end
  commit(s)
  return before - #s.comments
end

---@param id string
---@return string
local function saved_path(id)
  assert(
    type(id) == 'string' and id:match('^[a-f0-9]+$') and #id == 24,
    'synapse: invalid saved session ID'
  )
  return config.storage_dir .. '/' .. id .. '.json'
end

---@param s any Decoded JSON; validate before accepting it as session state.
---@param id string
---@return synapse.State
local function validate_saved(s, id)
  assert(
    type(s) == 'table' and s.version == 1 and s.session_id == id,
    'synapse: invalid saved session'
  )
  assert(
    s.project_root == current().project_root,
    'synapse: saved session belongs to a different project'
  )
  assert(
    integer(s.next_id) and type(s.comments) == 'table' and vim.islist(s.comments),
    'synapse: invalid saved comments'
  )
  ---@type table<string, synapse.Comment>
  local seen = {}
  for _, c in ipairs(s.comments) do
    assert(type(c) == 'table' and type(c.id) == 'string', 'synapse: invalid saved comment')
    local number = tonumber(c.id:match('^c([1-9]%d*)$'))
    assert(
      number and number < s.next_id and not seen[c.id],
      'synapse: invalid saved comment identity'
    )
    assert(c.author == 'human' or c.author == 'agent', 'synapse: invalid saved author')
    assert(nonblank(c.body), 'synapse: invalid saved body')
    local a = c.anchor
    assert(
      type(a) == 'table' and nonblank(a.file) and not a.file:match('^/') and not a.file:find('\0'),
      'synapse: invalid saved anchor'
    )
    assert(
      vim.fs.normalize(a.file) == a.file and a.file ~= '..' and not a.file:match('^%.%./'),
      'synapse: invalid saved path'
    )
    assert(
      integer(a.line) and integer(a.end_line) and a.end_line >= a.line,
      'synapse: invalid saved coordinates'
    )
    if c.parent_id ~= nil then
      local parent = seen[c.parent_id]
      assert(
        parent and vim.deep_equal(parent.anchor, a),
        'synapse: invalid saved parent or inherited anchor'
      )
    end
    seen[c.id] = c
  end
  return s
end

---@return synapse.SavedSession[]
function M.saved_sessions()
  current()
  local result = {}
  for _, path in ipairs(storage.files(config.storage_dir)) do
    local id = vim.fn.fnamemodify(path, ':t:r')
    local ok, s = pcall(function()
      return validate_saved(storage.read(saved_path(id)), id)
    end)
    if ok then
      result[#result + 1] =
        { session_id = id, project_root = s.project_root, comment_count = #s.comments }
    end
  end
  return result
end

---Resume a snapshot as an independent copy, never as a second writer to its identity.
---@param id string
---@param opts? synapse.ResumeOpts
---@return synapse.Info
function M.resume(id, opts)
  local s = current()
  assert(
    #s.comments == 0 or (opts and opts.confirm == true),
    'synapse: resuming over comments requires confirm=true'
  )
  local saved = validate_saved(storage.read(saved_path(id)), id)
  saved.session_id = s.session_id
  commit(saved, true)
  return M.info()
end

---@param author? synapse.Author
---@return synapse.Thread[]
function M.threads(author)
  ---@diagnostic disable-next-line: unnecessary-assert -- Keep validation for untyped/RPC callers.
  assert(author == nil or author == 'human' or author == 'agent', 'synapse: invalid author filter')
  ---@type synapse.Thread[]
  local threads = {}
  ---@type table<string, synapse.Thread>
  local by_comment = {}
  for _, c in ipairs(current().comments) do
    local thread = c.parent_id and by_comment[c.parent_id] or nil
    if not thread then
      thread = { id = c.id, anchor = c.anchor, comments = {} }
      threads[#threads + 1] = thread
    end
    thread.comments[#thread.comments + 1] = c
    by_comment[c.id] = thread
  end
  if author then
    threads = vim.tbl_filter(function(thread)
      for _, c in ipairs(thread.comments) do
        if c.author == author then
          return true
        end
      end
      return false
    end, threads)
  end
  return vim.deepcopy(threads)
end

return M
