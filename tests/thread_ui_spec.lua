local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local project = ''
t.describe('thread outline and detail', function()
  t.before_each(function()
    project = vim.fn.tempname()
    vim.fn.mkdir(project, 'p')
    vim.fn.writefile({ 'one', 'two' }, project .. '/code.lua')
    n.clear()
    n.exec_lua(function(root)
      local s = require('synapse')
      s.setup({ root = root, discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
      vim.cmd.edit(root .. '/code.lua')
      local function agent(parent, body)
        require('synapse.agent').dispatch({
          session_id = s.info().session_id,
          op = 'comment',
          args = { parent_id = parent, body = body },
        })
      end
      s.comment({
        file = 'code.lua',
        line = 1,
        body = 'Root question.' .. ('\nA longer review note.'):rep(40),
      })
      agent(
        'c1',
        'Agent explanation.\n\n```lua\nlocal value = 1\n```' .. ('\nMore explanation.'):rep(40)
      )
      s.comment({ parent_id = 'c1', body = 'Another question.' })
      agent('c2', 'Implementation details.')
      agent('c3', 'The other branch.')
    end, project)
  end)
  t.after_each(function()
    n.clear()
    vim.fn.delete(project, 'rf')
  end)

  t.it('keeps normal detail motions independent from outline selection', function()
    local screen = Screen.new(80, 24)
    n.exec_lua([[require('synapse').view('c1')]])
    screen:expect({ any = 'Reply outline' })
    local outline = n.api.nvim_get_current_win()
    n.feed('j')
    local selection = n.api.nvim_win_get_cursor(outline)
    n.feed('<Tab>')
    local detail = n.api.nvim_get_current_win()
    local cursor = n.api.nvim_win_get_cursor(detail)
    n.feed('j')
    t.eq({ cursor[1] + 1, cursor[2] }, n.api.nvim_win_get_cursor(detail))
    t.eq(selection, n.api.nvim_win_get_cursor(outline))
    n.feed('k')
    t.eq(cursor, n.api.nvim_win_get_cursor(detail))
    n.feed('<C-d>')
    local scrolled = n.api.nvim_win_get_cursor(detail)
    t.eq(true, scrolled[1] > cursor[1])
    t.eq(selection, n.api.nvim_win_get_cursor(outline))
    n.feed('<Tab><S-Tab>')
    t.eq(detail, n.api.nvim_get_current_win())
    t.eq(scrolled, n.api.nvim_win_get_cursor(detail))
    n.feed('<C-u>')
    t.eq(true, n.api.nvim_win_get_cursor(detail)[1] < scrolled[1])
    t.eq(selection, n.api.nvim_win_get_cursor(outline))
  end)

  t.it('scopes outline shortcuts and navigates comments explicitly from either pane', function()
    local screen = Screen.new(80, 24)
    n.exec_lua([[require('synapse').view('c1')]])
    screen:expect({ any = 'Reply outline' })
    local outline_buf = n.api.nvim_get_current_buf()
    n.feed('j<Tab>')
    local detail_buf = n.api.nvim_get_current_buf()
    local function heading()
      return n.api.nvim_buf_get_lines(detail_buf, 0, 1, false)[1]
    end
    t.eq('## Agent · c2', heading())
    local text = table.concat(n.api.nvim_buf_get_lines(detail_buf, 0, -1, false), '\n')
    t.eq(true, text:find('c1 YOU → c2 AGENT', 1, true) ~= nil)
    t.eq(false, text:find('REPLYING TO', 1, true) ~= nil)
    t.eq(false, text:find('Root question.', 1, true) ~= nil)
    n.feed(']c')
    t.eq('## Agent · c4', heading())
    n.feed('[c')
    t.eq('## Agent · c2', heading())
    n.feed('[p')
    t.eq('## You · c1', heading())
    n.feed('<Tab>zaj')
    t.eq('## You · c1', heading())
    n.feed('zaj')
    t.eq('## Agent · c2', heading())
    n.feed('p')
    t.eq('## You · c1', heading())

    for _, buf in ipairs({ outline_buf, detail_buf }) do
      for _, map in ipairs(n.api.nvim_buf_get_keymap(buf, 'n')) do
        t.eq(false, vim.tbl_contains({ '1', '2', '3', '<Left>', '<Right>' }, map.lhs))
        if buf == detail_buf then
          t.eq(false, vim.tbl_contains({ 'j', 'k', 'p', 'za' }, map.lhs))
        end
      end
    end
  end)

  t.it('docks replies below the detail pane without covering either reading pane', function()
    local screen = Screen.new(80, 24)
    n.exec_lua([[require('synapse').view('c1')]])
    screen:expect({ any = 'Reply outline' })
    local outline = n.api.nvim_get_current_win()
    n.feed('j<Tab>5j')
    local detail = n.api.nvim_get_current_win()
    n.feed('r')
    local draft = n.api.nvim_get_current_win()
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'docked sample reply' })
    local function check_docked()
      local context, editor = n.api.nvim_win_get_config(detail), n.api.nvim_win_get_config(draft)
      t.eq(context.col, editor.col)
      t.eq(context.width, editor.width)
      t.eq(true, assert(context.row) + context.height + 2 <= assert(editor.row))
      local tree = n.api.nvim_win_get_config(outline)
      t.eq(true, assert(tree.col) + tree.width + 2 <= assert(editor.col))
      t.eq(tree.row, context.row)
      t.eq(tree.height, context.height + editor.height + 2)
    end
    check_docked()
    n.feed('<Esc><C-w>p')
    t.eq(detail, n.api.nvim_get_current_win())
    n.feed('r')
    t.eq(draft, n.api.nvim_get_current_win())
    screen:try_resize(100, 30)
    n.api.nvim_eval('1')
    check_docked()
    t.eq({ 'docked sample reply' }, n.api.nvim_buf_get_lines(0, 0, -1, false))
    n.feed('<C-s>')
    t.eq(false, n.api.nvim_win_is_valid(draft))
    t.eq(n.api.nvim_win_get_height(outline), n.api.nvim_win_get_height(detail))
    t.eq('## You · c6', n.api.nvim_buf_get_lines(n.api.nvim_win_get_buf(detail), 0, 1, false)[1])
  end)

  t.it(
    'returns cancelled drafts to the reading pane and reopens without leaking windows',
    function()
      local screen = Screen.new(80, 24)
      local origin = n.api.nvim_get_current_win()
      n.exec_lua([[require('synapse').view('c1')]])
      screen:expect({ any = 'Reply outline' })
      n.feed('<Tab>5j')
      local detail = n.api.nvim_get_current_win()
      local cursor = n.api.nvim_win_get_cursor(detail)
      n.feed('r')
      n.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsent sample reply' })
      n.feed('<C-c>')
      t.eq(detail, n.api.nvim_get_current_win())
      t.eq(cursor, n.api.nvim_win_get_cursor(detail))
      n.exec_lua([[vim.api.nvim_exec_autocmds('VimResized', {})]])
      t.eq('## You · c1', n.api.nvim_buf_get_lines(n.api.nvim_get_current_buf(), 0, 1, false)[1])
      local count = #n.api.nvim_list_wins()
      n.exec_lua([[require('synapse').view('c1')]])
      t.eq(count, #n.api.nvim_list_wins())
      n.feed('q')
      t.eq({ origin }, n.api.nvim_list_wins())
      t.eq(5, n.exec_lua([[return #require('synapse').threads()[1].comments]]))
    end
  )

  t.it('refreshes live comments without moving the reader and falls back after deletion', function()
    local screen = Screen.new(80, 24)
    local detail = n.exec_lua([[return require('synapse').view('c2')]])
    screen:expect({ any = 'Reply outline' })
    n.feed('<Tab>10j')
    local position = n.api.nvim_win_get_cursor(detail.winid)
    n.exec_lua(function()
      local s = require('synapse')
      require('synapse.agent').dispatch({
        session_id = s.info().session_id,
        op = 'comment',
        args = { parent_id = 'c2', body = 'A live update.' },
      })
    end)
    t.eq(position, n.api.nvim_win_get_cursor(detail.winid))
    t.eq(
      true,
      table
        .concat(n.api.nvim_buf_get_lines(detail.bufnr, 0, -1, false), '\n')
        :find('A live update.', 1, true) ~= nil
    )
    n.exec_lua([[require('synapse').view('c4'); require('synapse').delete('c4')]])
    t.eq('## You · c1', n.api.nvim_buf_get_lines(detail.bufnr, 0, 1, false)[1])
    n.feed('za')
    local outline = n.api.nvim_get_current_buf()
    n.exec_lua([[require('synapse').comment({parent_id = 'c1', body = 'Another live reply.'})]])
    t.eq(
      false,
      table.concat(n.api.nvim_buf_get_lines(outline, 0, -1, false), '\n'):find('c2 AGENT', 1, true)
        ~= nil
    )
  end)

  t.it('keeps a draft when its thread disappears and rejects the missing reply target', function()
    Screen.new(80, 24)
    local origin = n.api.nvim_get_current_win()
    n.exec_lua([[vim.notify = function(message) vim.g.submission_error = message end
      require('synapse').compose({parent_id = 'c2'})]])
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'Do not lose this draft.' })
    local draft = n.api.nvim_get_current_buf()
    n.exec_lua([[require('synapse').clear({confirm = true, include_human = true})]])
    t.eq(2, #n.api.nvim_list_wins())
    t.eq(draft, n.api.nvim_get_current_buf())
    n.feed('<C-s>')
    t.eq({ 'Do not lose this draft.' }, n.api.nvim_buf_get_lines(draft, 0, -1, false))
    t.eq(0, n.exec_lua([[return #require('synapse').threads()]]))
    t.matches('unknown comment', n.eval('g:submission_error'))
    n.feed('q')
    t.eq({ origin }, n.api.nvim_list_wins())
  end)

  t.it('cleans up externally closed panes without discarding an open draft', function()
    Screen.new(80, 24)
    local origin = n.api.nvim_get_current_win()
    local detail = n.exec_lua([[return require('synapse').view('c1')]])
    local outline = n.api.nvim_get_current_win()
    n.feed('r')
    local draft = n.api.nvim_get_current_buf()
    n.api.nvim_buf_set_lines(draft, 0, -1, false, { 'Still editing.' })
    n.api.nvim_win_close(outline, true)
    t.eq(false, n.api.nvim_win_is_valid(detail.winid))
    t.eq(2, #n.api.nvim_list_wins())
    t.eq({ 'Still editing.' }, n.api.nvim_buf_get_lines(draft, 0, -1, false))
    n.feed('<C-s>')
    t.eq({ origin }, n.api.nvim_list_wins())
    t.eq('Still editing.', n.exec_lua([[return require('synapse').threads()[1].comments[6].body]]))
  end)

  t.it('retains a failed submission for retry and never overwrites an existing draft', function()
    Screen.new(80, 24)
    local first = n.exec_lua([[return require('synapse').compose({parent_id = 'c2'})]])
    n.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { 'A retryable reply.' })
    local same = n.exec_lua([[return require('synapse').compose({id = 'c1'})]])
    t.eq(first, same)
    n.exec_lua([[
      vim.notify = function(message) vim.g.submission_error = message end
      local storage = require('synapse.storage')
      local original = storage.write
      storage.write = function()
        storage.write = original
        error('simulated save failure')
      end
    ]])
    n.feed('<C-s>')
    t.eq({ 'A retryable reply.' }, n.api.nvim_buf_get_lines(first.bufnr, 0, -1, false))
    t.eq(5, n.exec_lua([[return #require('synapse').threads()[1].comments]]))
    t.matches('simulated save failure', n.eval('g:submission_error'))
    n.feed('<C-s>')
    t.eq(false, n.api.nvim_buf_is_valid(first.bufnr))
    t.eq(
      { 'c2', 'A retryable reply.' },
      n.exec_lua([[
      local reply = require('synapse').threads()[1].comments[6]
      return {reply.parent_id, reply.body}
    ]])
    )
  end)
end)
