local M = {}
local session = require('synapse.session')
local api = vim.api
local namespace = api.nvim_create_namespace('synapse.ui')
local initialized = false
---@type table<integer, fun()>
local quickfix_maps = {}

---@class synapse.Window
---@field bufnr integer
---@field winid integer

---@class synapse.ViewOpts
---@field line? integer First line in the current buffer; defaults to the cursor.
---@field end_line? integer Last line, inclusive; defaults to line.

---@class synapse.Panel : synapse.Window
---@field close fun()

---@class synapse.ThreadView
---@field id string
---@field selected string
---@field generation integer
---@field origin integer
---@field outline synapse.Panel
---@field detail synapse.Panel
---@field status synapse.Panel
---@field collapsed table<string, boolean>
---@field comments table<string, synapse.Comment>
---@field visible string[]

---@class synapse.Draft : synapse.Panel
---@field context? synapse.ThreadView

---@type synapse.ThreadView?
local view
---@type synapse.Draft?
local draft

---@param title string
---@param editable boolean
---@return synapse.Panel
local function panel(title, editable)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = editable and 'markdown' or 'synapse'
  vim.bo[buf].modifiable = editable
  local win = api.nvim_open_win(buf, false, {
    relative = 'editor',
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    width = 1,
    height = 1,
    row = 0,
    col = 0,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local function close()
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  return { bufnr = buf, winid = win, close = close }
end

---Resize existing windows rather than recreating buffers or discarding reading positions.
local function layout()
  if view and vim.o.columns >= 60 and vim.o.lines >= 16 then
    local width = math.min(106, vim.o.columns - 4)
    local height = math.min(32, vim.o.lines - 7)
    local top = math.max(0, math.floor((vim.o.lines - height - 7) / 2))
    local left = math.floor((vim.o.columns - width - 2) / 2)
    local sidebar = math.floor(width * 0.38)
    local composing = draft and draft.context == view
    local editor_height = composing and math.min(8, math.max(3, math.floor(height / 3))) or 0
    local detail_height = composing and height - editor_height - 2 or height
    api.nvim_win_set_config(
      view.outline.winid,
      { relative = 'editor', row = top, col = left, width = sidebar, height = height }
    )
    api.nvim_win_set_config(view.detail.winid, {
      relative = 'editor',
      row = top,
      col = left + sidebar + 2,
      width = width - sidebar - 2,
      height = detail_height,
    })
    api.nvim_win_set_config(view.status.winid, {
      relative = 'editor',
      row = top + height + 2,
      col = left,
      width = width,
      height = 2,
      focusable = false,
    })
    if composing and draft then
      api.nvim_win_set_config(draft.winid, {
        relative = 'editor',
        row = top + detail_height + 2,
        col = left + sidebar + 2,
        width = width - sidebar - 2,
        height = editor_height,
      })
    end
  end
  if draft and not draft.context then
    local width = math.max(1, math.min(80, vim.o.columns - 4))
    local height = math.max(1, math.min(16, vim.o.lines - 6))
    api.nvim_win_set_config(draft.winid, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    })
  end
end

---@param skip? integer Buffer already being wiped.
local function close_view(skip)
  local current = view
  if not current then
    return
  end
  view = nil
  local in_draft = draft and api.nvim_get_current_win() == draft.winid
  if draft and draft.context == current then
    draft.context = nil
  end
  for _, p in ipairs({ current.outline, current.detail, current.status }) do
    if p.bufnr ~= skip then
      p.close()
    end
  end
  layout()
  if not in_draft and api.nvim_win_is_valid(current.origin) then
    api.nvim_set_current_win(current.origin)
  end
end

---@param id string
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

---@param c synapse.Comment
local function label(c)
  return c.id .. ' ' .. (c.author == 'human' and 'YOU' or 'AGENT')
end

---@param c synapse.Comment
local function role(c)
  return c.author == 'human' and 'SynapseHuman' or 'SynapseAgent'
end

---@param p synapse.Panel
---@param lines string[]
local function write(p, lines)
  if vim.deep_equal(api.nvim_buf_get_lines(p.bufnr, 0, -1, false), lines) then
    return
  end
  local saved = api.nvim_win_call(p.winid, vim.fn.winsaveview)
  vim.bo[p.bufnr].modifiable = true
  api.nvim_buf_set_lines(p.bufnr, 0, -1, false, lines)
  vim.bo[p.bufnr].modifiable = false
  api.nvim_win_call(p.winid, function()
    vim.fn.winrestview(saved)
  end)
end

---@param p synapse.Panel
---@param row integer Zero-based row.
---@param group string
---@param selected? boolean
local function highlight(p, row, group, selected)
  api.nvim_buf_set_extmark(p.bufnr, namespace, row, 0, {
    line_hl_group = selected and 'Visual' or nil,
    end_row = row + 1,
    hl_group = group,
    hl_eol = true,
  })
end

---@param reset? boolean A different comment was selected.
local function refresh_view(reset)
  local current = view
  if not current then
    return
  end
  local ok, _, thread = pcall(comment, current.id)
  if not ok or current.generation ~= session.info().generation then
    close_view()
    return
  end
  current.comments = {}
  ---@type table<string, synapse.Comment[]>
  local children = {}
  for _, c in ipairs(thread.comments) do
    current.comments[c.id] = c
    if c.parent_id then
      children[c.parent_id] = children[c.parent_id] or {}
      table.insert(children[c.parent_id], c)
    end
  end
  if not current.comments[current.selected] then
    current.selected = thread.id
    reset = true
  end
  local selected = current.comments[current.selected]
  local lines = { 'REPLIES', '' }
  local headers = {}
  local selected_row = 1
  current.visible = {}
  local function visit(c, prefix, branch, continuation)
    current.visible[#current.visible + 1] = c.id
    local row = #lines
    local kids = children[c.id] or {}
    local fold = #kids == 0 and '· ' or (current.collapsed[c.id] and '▸ ' or '▾ ')
    lines[#lines + 1] = prefix .. branch .. fold .. label(c)
    local preview = (c.body:match('[^\n]*') or '')
    lines[#lines + 1] = prefix .. continuation .. '  ' .. preview
    lines[#lines + 1] = ''
    headers[#headers + 1] = { row = row, c = c }
    if c.id == current.selected then
      selected_row = row + 1
    end
    if not current.collapsed[c.id] then
      for i, child in ipairs(kids) do
        local last = i == #kids
        visit(
          child,
          prefix .. continuation,
          last and '└─ ' or '├─ ',
          last and '   ' or '│  '
        )
      end
    end
  end
  visit(current.comments[thread.id], '', '', '')
  write(current.outline, lines)
  api.nvim_buf_clear_namespace(current.outline.bufnr, namespace, 0, -1)
  for _, h in ipairs(headers) do
    highlight(current.outline, h.row, role(h.c), h.c.id == current.selected)
  end
  api.nvim_win_set_cursor(current.outline.winid, { selected_row, 0 })
  local a = thread.anchor
  lines = {
    (selected.author == 'human' and '## You' or '## Agent') .. ' · ' .. selected.id,
    a.file .. ':' .. a.line .. '-' .. a.end_line,
  }
  local ancestry = {}
  local parent = selected.parent_id
  while parent do
    local c = current.comments[parent]
    table.insert(ancestry, 1, label(c))
    parent = c.parent_id
  end
  if #ancestry > 0 then
    ancestry[#ancestry + 1] = label(selected)
    lines[#lines + 1] = table.concat(ancestry, ' → ')
  end
  lines[#lines + 1] = ''
  vim.list_extend(lines, vim.split(selected.body, '\n', { plain = true }))
  local kids = children[selected.id] or {}
  if #kids > 0 then
    vim.list_extend(lines, { '', '## Replies' })
    for _, child in ipairs(kids) do
      lines[#lines + 1] = label(child) .. ': ' .. child.body:match('[^\n]*')
    end
  end
  write(current.detail, lines)
  api.nvim_buf_clear_namespace(current.detail.bufnr, namespace, 0, -1)
  highlight(current.detail, 0, role(selected))
  highlight(current.detail, 1, 'Comment')
  if #ancestry > 0 then
    highlight(current.detail, 2, 'Comment')
  end
  if reset then
    api.nvim_win_set_cursor(current.detail.winid, { 1, 0 })
    api.nvim_win_call(current.detail.winid, function()
      vim.fn.winrestview({ topline = 1 })
    end)
  end
  write(current.status, {
    'Tab pane  [c/]c comment  [p parent  r reply  e edit  q close',
    label(selected) .. ' · ' .. #thread.comments .. ' comments · outline: j/k select, za fold',
  })
end

---@param id string
local function select(id)
  if not view or not view.comments[id] then
    return
  end
  local changed = view.selected ~= id
  view.selected = id
  local parent = view.comments[id].parent_id
  while parent do
    view.collapsed[parent] = nil
    parent = view.comments[parent].parent_id
  end
  refresh_view(changed)
end

---@param delta integer
local function move(delta)
  if not view then
    return
  end
  for i, id in ipairs(view.visible) do
    if id == view.selected then
      select(assert(view.visible[math.max(1, math.min(#view.visible, i + delta))]))
      return
    end
  end
end

---Compose a human comment, reply (parent_id), or edit (id). Drafts are not persisted.
---@param options? synapse.ComposeOpts
---@return synapse.Window
function M.compose(options)
  if draft then
    api.nvim_set_current_win(draft.winid)
    return { bufnr = draft.bufnr, winid = draft.winid }
  end
  local generation = session.info().generation
  local opts = vim.deepcopy(options or {})
  local existing = opts.id and comment(opts.id)
  if existing then
    assert(existing.author == 'human', 'synapse: only human comments can be edited')
  elseif not opts.parent_id then
    opts.file = opts.file or api.nvim_buf_get_name(0)
    opts.line = opts.line or api.nvim_win_get_cursor(0)[1]
    opts.end_line = opts.end_line or opts.line
  end
  local return_to = api.nvim_get_current_win()
  local id = opts.id or opts.parent_id
  if id then
    local _, thread = comment(id)
    if not view or view.id ~= thread.id then
      M.view(id)
    else
      select(id)
    end
  end
  local context = id and view or nil
  -- A docked editor should return to the reading pane, not an unrelated source window.
  if context and return_to ~= context.outline.winid and return_to ~= context.detail.winid then
    return_to = context.detail.winid
  end
  local context_view = context and api.nvim_win_call(context.detail.winid, vim.fn.winsaveview)
  local title = opts.id and ('Edit ' .. opts.id)
    or (opts.parent_id and ('Reply to ' .. opts.parent_id) or 'Synapse comment')
  local p = panel(title, true) --[[@as synapse.Draft]]
  p.context = context
  draft = p
  api.nvim_buf_set_lines(
    p.bufnr,
    0,
    -1,
    false,
    existing and vim.split(existing.body, '\n', { plain = true }) or { '' }
  )
  api.nvim_win_set_config(p.winid, { footer = ' Ctrl-S send · Ctrl-C cancel ' })
  api.nvim_create_autocmd('BufWipeout', {
    buffer = p.bufnr,
    once = true,
    callback = function()
      draft = nil
      layout()
      if context and context_view and context == view then
        api.nvim_win_call(context.detail.winid, function()
          vim.fn.winrestview(context_view)
        end)
      end
      if api.nvim_win_is_valid(return_to) then
        api.nvim_set_current_win(return_to)
      end
    end,
  })
  local function cancel()
    vim.cmd.stopinsert()
    p.close()
  end
  vim.keymap.set('n', 'q', cancel, { buffer = p.bufnr, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-c>', cancel, { buffer = p.bufnr })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    local body = table.concat(api.nvim_buf_get_lines(p.bufnr, 0, -1, false), '\n')
    local ok, result = pcall(function()
      assert(
        generation == session.info().generation,
        'synapse: conversation was resumed; copy this draft into a new composition'
      )
      if opts.id then
        return session.edit(opts.id, body)
      end
      return session.comment(
        vim.tbl_extend('force', opts, { body = body }) --[[@as synapse.CommentInput]],
        'human'
      )
    end)
    if ok then
      cancel()
      if view and context == view then
        select(result.id)
      end
    else
      vim.notify(tostring(result), vim.log.levels.ERROR)
    end
  end, { buffer = p.bufnr })
  layout()
  api.nvim_set_current_win(p.winid)
  return { bufnr = p.bufnr, winid = p.winid }
end

---Read a thread by comment ID, or find threads overlapping the current buffer's line range.
---@param target? string|synapse.ViewOpts
---@return synapse.Window?
function M.view(target)
  if type(target) ~= 'string' then
    local opts = target or {}
    local line = opts.line or api.nvim_win_get_cursor(0)[1]
    local last = opts.end_line or line
    local name = api.nvim_buf_get_name(0)
    name = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
    local info = session.info()
    local matches = {}
    for _, thread in ipairs(session.threads()) do
      local a = thread.anchor
      if
        vim.fs.joinpath(info.project_root, a.file) == name
        and a.line <= last
        and a.end_line >= line
      then
        matches[#matches + 1] = thread
      end
    end
    if #matches == 0 then
      vim.notify('synapse: no threads on these lines', vim.log.levels.INFO)
    elseif #matches == 1 then
      return M.view(matches[1].id)
    else
      vim.ui.select(matches, {
        prompt = 'Synapse thread:',
        format_item = function(thread)
          local first = assert(thread.comments[1])
          return ('%s:%d-%d [%s] %s'):format(
            thread.id,
            thread.anchor.line,
            thread.anchor.end_line,
            first.author,
            first.body:match('[^\n]*')
          )
        end,
      }, function(thread)
        if not thread then
          return
        end
        if info.generation ~= session.info().generation then
          vim.notify(
            'synapse: conversation was resumed; run :SynapseThread again',
            vim.log.levels.WARN
          )
          return
        end
        M.view(thread.id)
      end)
    end
    return
  end
  local _, thread = comment(target)
  assert(
    vim.o.columns >= 60 and vim.o.lines >= 16,
    'synapse: thread view needs at least 60 columns and 16 rows'
  )
  if view and view.id == thread.id then
    select(target)
    api.nvim_set_current_win(view.outline.winid)
    return { bufnr = view.detail.bufnr, winid = view.detail.winid }
  end
  close_view()
  local origin = api.nvim_get_current_win()
  local outline = panel('Reply outline', false)
  local detail = panel('Comment detail', false)
  local status = panel('Synapse', false)
  vim.bo[detail.bufnr].filetype = 'markdown'
  vim.wo[outline.winid].wrap = false
  vim.wo[status.winid].wrap = false
  view = {
    id = thread.id,
    selected = target,
    generation = session.info().generation,
    origin = origin,
    outline = outline,
    detail = detail,
    status = status,
    collapsed = {},
    comments = {},
    visible = {},
  }
  local function map(p, key, fn)
    vim.keymap.set('n', key, fn, { buffer = p.bufnr, nowait = true })
  end
  local function swap()
    api.nvim_set_current_win(
      api.nvim_get_current_win() == outline.winid and detail.winid or outline.winid
    )
  end
  local function parent()
    select(view.comments[view.selected].parent_id or view.selected)
  end
  for _, p in ipairs({ outline, detail }) do
    map(p, 'q', close_view)
    map(p, '<C-c>', close_view)
    map(p, '<Tab>', swap)
    map(p, '<S-Tab>', swap)
    map(p, ']c', function()
      move(1)
    end)
    map(p, '[c', function()
      move(-1)
    end)
    map(p, '[p', parent)
    map(p, 'r', function()
      M.compose({ parent_id = view.selected })
    end)
    map(p, 'e', function()
      M.compose({ id = view.selected })
    end)
  end
  map(outline, 'j', function()
    move(1)
  end)
  map(outline, 'k', function()
    move(-1)
  end)
  map(outline, 'p', parent)
  map(outline, 'za', function()
    view.collapsed[view.selected] = not view.collapsed[view.selected]
    refresh_view()
  end)
  layout()
  refresh_view(true)
  api.nvim_set_current_win(outline.winid)
  return { bufnr = detail.bufnr, winid = detail.winid }
end

---Quickfix contains one entry per thread, even when a reply matches the author filter.
---@param author? synapse.Author
---@return vim.quickfix.entry[]
function M.browse(author)
  ---@type vim.quickfix.entry[]
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
  vim.fn.setqflist({}, ' ', {
    title = 'Synapse threads',
    context = { synapse = true, generation = session.info().generation },
    items = items,
  })
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
    if list.context.generation ~= session.info().generation then
      vim.notify('synapse: conversation was resumed; run :SynapseBrowse again', vim.log.levels.WARN)
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

---@return nil
function M.setup()
  if initialized then
    return
  end
  initialized = true
  api.nvim_set_hl(0, 'SynapseHuman', { default = true, link = 'DiagnosticInfo' })
  api.nvim_set_hl(0, 'SynapseAgent', { default = true, link = 'DiagnosticWarn' })
  local group = api.nvim_create_augroup('synapse', { clear = true })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(event)
      quickfix_maps[event.buf] = nil
      if
        view
        and (
          event.buf == view.outline.bufnr
          or event.buf == view.detail.bufnr
          or event.buf == view.status.bufnr
        )
      then
        close_view(event.buf)
      end
    end,
  })
  api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'SynapseChanged',
    callback = function()
      refresh_view()
    end,
  })
  api.nvim_create_autocmd('VimResized', { group = group, callback = layout })
end

return M
