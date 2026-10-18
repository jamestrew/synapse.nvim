local M = {}
local session = require('synapse.session')
local api = vim.api
local initialized = false
local quickfix_maps = {}
---@type { bufnr: integer, winid: integer, close: fun(), id: string, rows: string[] }?
local view

local function float(title, lines, editable)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = editable and 'markdown' or 'synapse'
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = editable
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local height = math.max(1, math.min(16, vim.o.lines - 6))
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = 'rounded',
    title = title,
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.wo[win].wrap = true
  local function close()
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-c>', close, { buffer = buf })
  return { bufnr = buf, winid = win, close = close }
end

---@return synapse.Comment, synapse.Thread
local function comment(id)
  for _, thread in ipairs(session.threads()) do
    for _, c in ipairs(thread.comments) do
      if c.id == id then
        return c, thread
      end
    end
  end
  error('synapse: unknown comment: ' .. tostring(id))
end

local function refresh_view()
  if not view or not api.nvim_buf_is_valid(view.bufnr) then
    return
  end
  local ok, _, thread = pcall(comment, view.id)
  if not ok then
    view.close()
    view = nil
    return
  end
  local a = thread.anchor
  local lines = { a.file .. ':' .. a.line .. '-' .. a.end_line, '' }
  local rows = { thread.id, thread.id }
  for _, c in ipairs(thread.comments) do
    local text =
      { ('[%s] %s%s'):format(c.author, c.id, c.parent_id and (' -> ' .. c.parent_id) or '') }
    vim.list_extend(text, vim.split(c.body, '\n', { plain = true }))
    text[#text + 1] = ''
    for _, line in ipairs(text) do
      lines[#lines + 1] = line
      rows[#rows + 1] = c.id
    end
  end
  vim.bo[view.bufnr].modifiable = true
  api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.bo[view.bufnr].modifiable = false
  view.rows = rows
end

---Compose a human comment, reply (parent_id), or edit (id). Drafts are not persisted.
function M.compose(opts)
  local generation = session.info().generation
  opts = vim.deepcopy(opts or {})
  local lines = { '' }
  if opts.id then
    local c = comment(opts.id)
    assert(c.author == 'human', 'synapse: only human comments can be edited')
    lines = vim.split(c.body, '\n', { plain = true })
  elseif not opts.parent_id then
    opts.file = opts.file or api.nvim_buf_get_name(0)
    opts.line = opts.line or api.nvim_win_get_cursor(0)[1]
    opts.end_line = opts.end_line or opts.line
  else
    comment(opts.parent_id)
  end
  local draft = float(' Synapse compose: Ctrl-S submit / q cancel ', lines, true)
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    local body = table.concat(api.nvim_buf_get_lines(draft.bufnr, 0, -1, false), '\n')
    local ok, err = pcall(function()
      assert(
        generation == session.info().generation,
        'synapse: conversation was resumed; copy this draft into a new composition'
      )
      if opts.id then
        session.edit(opts.id, body)
      else
        opts.body = body
        session.comment(opts, 'human')
      end
    end)
    if ok then
      vim.cmd.stopinsert()
      draft.close()
    else
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end, { buffer = draft.bufnr })
  return { bufnr = draft.bufnr, winid = draft.winid }
end

---Read the whole thread containing a comment; actions apply to the comment under the cursor.
function M.view(id)
  local _, thread = comment(id)
  if view then
    view.close()
  end
  local panel = float(' Synapse thread: r reply / e edit / q close ', { '' }, false)
  view =
    { bufnr = panel.bufnr, winid = panel.winid, close = panel.close, id = thread.id, rows = {} }
  local function selected()
    return view.rows[api.nvim_win_get_cursor(view.winid)[1]] or view.id
  end
  vim.keymap.set('n', 'r', function()
    M.compose({ parent_id = selected() })
  end, { buffer = view.bufnr })
  vim.keymap.set('n', 'e', function()
    M.compose({ id = selected() })
  end, { buffer = view.bufnr })
  refresh_view()
  return { bufnr = view.bufnr, winid = view.winid }
end

---Quickfix contains one entry per thread, even when a reply matches the author filter.
function M.browse(author)
  local items = {}
  for _, thread in ipairs(session.threads(author)) do
    local a = thread.anchor
    local first = assert(thread.comments[1])
    items[#items + 1] = {
      filename = vim.fs.joinpath(session.info().project_root, a.file),
      lnum = a.line,
      end_lnum = a.end_line,
      col = 1,
      text = ('[%s] %s (%d comments)'):format(
        first.author,
        first.body:match('[^\n]*'),
        #thread.comments
      ),
      user_data = { synapse_thread_id = thread.id },
    }
  end
  vim.fn.setqflist(
    {},
    ' ',
    { title = 'Synapse threads', context = { synapse = true }, items = items }
  )
  vim.cmd.copen()
  local buf = api.nvim_get_current_buf()
  local previous = vim.fn.maparg('<CR>', 'n', false, true)
  if quickfix_maps[buf] and quickfix_maps[buf] == previous.callback then
    return items
  end
  local function enter()
    local list = vim.fn.getqflist({ idx = 0, items = 0, context = 0 })
    if type(list.context) ~= 'table' or not list.context.synapse then
      vim.keymap.del('n', '<CR>', { buffer = buf })
      if previous.buffer == 1 then
        vim.fn.mapset('n', false, previous)
      end
      quickfix_maps[buf] = nil
      api.nvim_feedkeys(vim.keycode('<CR>'), 'm', false)
      return
    end
    local item = list.items[list.idx]
    if not item then
      return
    end
    vim.cmd.cclose()
    vim.cmd.cc(list.idx)
    local data = item.user_data
    if type(data) == 'table' and data.synapse_thread_id then
      M.view(data.synapse_thread_id)
    end
  end
  quickfix_maps[buf] = enter
  vim.keymap.set('n', '<CR>', enter, { buffer = buf })
  return items
end

function M.setup()
  if initialized then
    return
  end
  initialized = true
  local group = api.nvim_create_augroup('synapse', { clear = true })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(event)
      quickfix_maps[event.buf] = nil
    end,
  })
  api.nvim_create_autocmd(
    'User',
    { group = group, pattern = 'SynapseChanged', callback = refresh_view }
  )
  api.nvim_create_user_command('SynapseDelete', function(args)
    session.delete(args.args)
  end, { nargs = 1 })
  api.nvim_create_user_command('SynapseClear', function(args)
    local scope = args.bang and 'ALL human and agent comments' or 'agent comments'
    if vim.fn.confirm('Clear ' .. scope .. '?', '&Yes\n&No', 2) == 1 then
      session.clear({ confirm = true, include_human = args.bang })
    end
  end, { bang = true })
  api.nvim_create_user_command('SynapseResume', function(args)
    session.resume(args.args)
  end, {
    nargs = 1,
    complete = function()
      return vim.tbl_map(function(saved)
        return saved.session_id
      end, session.saved_sessions())
    end,
  })
  api.nvim_create_user_command('SynapseComment', function(args)
    M.compose({ line = args.line1, end_line = args.line2 })
  end, { range = true })
  api.nvim_create_user_command('SynapseBrowse', function(args)
    M.browse(args.args ~= '' and args.args or nil)
  end, {
    nargs = '?',
    complete = function()
      return { 'human', 'agent' }
    end,
  })
  api.nvim_create_user_command('SynapseThread', function(args)
    M.view(args.args)
  end, { nargs = 1 })
  api.nvim_create_user_command('SynapseReply', function(args)
    M.compose({ parent_id = args.args })
  end, { nargs = 1 })
  api.nvim_create_user_command('SynapseEdit', function(args)
    M.compose({ id = args.args })
  end, { nargs = 1 })
end

return M
