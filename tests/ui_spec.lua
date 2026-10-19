local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local project = ''
t.describe('human conversation UI', function()
  t.before_each(function()
    project = vim.fn.tempname()
    vim.fn.mkdir(project, 'p')
    vim.fn.writefile({ 'one', 'two', 'three', 'four' }, project .. '/code.lua')
    n.clear()
    n.exec_lua(function(root)
      require('synapse').setup({
        root = root,
        discovery_dir = root .. '/live',
        storage_dir = root .. '/saved',
      })
      vim.cmd.edit(root .. '/code.lua')
    end, project)
  end)
  t.after_each(function()
    n.clear()
    vim.fn.delete(project, 'rf')
  end)

  t.it('composes multiline range comments and reads a separate, read-only transcript', function()
    local screen = Screen.new(80, 24)
    t.eq(false, n.exec_lua([[return package.loaded['synapse.ui'] ~= nil]]))
    n.command('2,3SynapseComment')
    t.eq(true, n.exec_lua([[return package.loaded['synapse.ui'] ~= nil]]))
    t.eq(false, n.exec_lua([[return package.loaded['synapse.markers'] ~= nil]]))
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'Why this block?', 'Second line.' })
    screen:expect({ any = 'Why this block%?' })
    n.feed('<C-s>')
    t.eq(
      { 2, 3, 'Why this block?\nSecond line.' },
      n.exec_lua(function()
        local thread = assert(require('synapse').threads()[1])
        return { thread.anchor.line, thread.anchor.end_line, assert(thread.comments[1]).body }
      end)
    )
    n.command('SynapseThread c1')
    screen:expect({ any = '## You' })
    t.eq(false, n.api.nvim_get_option_value('modifiable', { buf = 0 }))
    n.feed('r')
    t.eq(true, n.api.nvim_get_option_value('modifiable', { buf = 0 }))
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'A reply' })
    n.feed('<C-s>')
    screen:expect({ any = 'A reply' })
    t.eq(2, n.exec_lua([[return #assert(require('synapse').threads()[1]).comments]]))
  end)

  t.it('renders highlighted Markdown headings while retaining reply and edit targets', function()
    t.eq(
      {
        'markdown',
        false,
        { '## Agent · c2', 'code.lua:2-2', 'c1 YOU → c2 AGENT', '', 'agent body' },
        { { 0, 'SynapseAgent' }, { 1, 'Comment' }, { 2, 'Comment' } },
      },
      n.exec_lua(function()
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 2, body = 'human body' })
        require('synapse.agent').dispatch({
          session_id = s.info().session_id,
          op = 'comment',
          args = { parent_id = 'c1', body = 'agent body' },
        })
        local panel = assert(s.view('c2'))
        local namespace = vim.api.nvim_get_namespaces()['synapse.ui']
        local headers = vim.tbl_map(function(mark)
          return { mark[2], assert(mark[4]).hl_group }
        end, vim.api.nvim_buf_get_extmarks(
          panel.bufnr,
          namespace,
          0,
          -1,
          { details = true }
        ))
        return {
          vim.bo[panel.bufnr].filetype,
          vim.bo[panel.bufnr].modifiable,
          vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false),
          headers,
        }
      end)
    )
    n.feed('r')
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'human reply' })
    n.feed('<C-s>')
    t.eq('c2', n.exec_lua([[return require('synapse').threads()[1].comments[3].parent_id]]))
    n.feed('[p[pe')
    t.eq({ 'human body' }, n.api.nvim_buf_get_lines(0, 0, -1, false))
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited human body' })
    n.feed('<C-s>')
    t.eq(
      'edited human body',
      n.exec_lua([[return require('synapse').threads()[1].comments[1].body]])
    )
  end)

  for _, height in ipairs({ 16, 24 }) do
    t.it(
      'keeps reply context visible and restores it after cancel or submit at height ' .. height,
      function()
        local screen = Screen.new(80, height)
        local transcript = n.exec_lua(function()
          local s = require('synapse')
          s.comment({ file = 'code.lua', line = 2, body = 'context remains visible' })
          return assert(s.view('c1'))
        end)
        local original = n.api.nvim_win_get_config(transcript.winid)
        n.feed('<Tab>r')
        local draft = n.api.nvim_get_current_win()
        n.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft being typed' })
        screen:expect({ any = 'context remains visible.-draft being typed' })
        local top, bottom =
          n.api.nvim_win_get_config(transcript.winid), n.api.nvim_win_get_config(draft)
        local top_row, bottom_row = assert(top.row), assert(bottom.row)
        t.eq(true, top_row + top.height + 2 <= bottom_row)
        t.eq(true, bottom_row + bottom.height + 2 <= height - 1)
        n.feed('<C-w>p')
        t.eq(transcript.winid, n.api.nvim_get_current_win())
        n.feed('<C-e><C-w>p')
        t.eq(draft, n.api.nvim_get_current_win())
        n.feed('<C-c>')
        t.eq(transcript.winid, n.api.nvim_get_current_win())
        t.eq(original, n.api.nvim_win_get_config(transcript.winid))
        t.eq(1, n.exec_lua([[return #require('synapse').threads()[1].comments]]))
        n.feed('r')
        n.api.nvim_buf_set_lines(0, 0, -1, false, { 'submitted reply' })
        n.feed('<C-s>')
        t.eq(transcript.winid, n.api.nvim_get_current_win())
        t.eq(original, n.api.nvim_win_get_config(transcript.winid))
        screen:expect({ any = 'submitted reply' })
      end
    )
  end

  t.it(
    'opens the current line thread through the command and Lua API, including range endpoints',
    function()
      n.exec_lua(function(root)
        vim.fn.writefile({ 'one', 'two', 'three', 'four' }, root .. '/other.lua')
        local s = require('synapse')
        s.comment({ file = 'other.lua', line = 2, end_line = 3, body = 'other file' })
        s.comment({ file = 'code.lua', line = 2, end_line = 3, body = 'current file' })
        s.comment({ parent_id = 'c2', body = 'whole thread reply' })
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
      end, project)
      n.command('SynapseThread')
      t.matches('whole thread reply', table.concat(n.api.nvim_buf_get_lines(0, 0, -1, false), '\n'))
      n.feed('q')
      t.eq(
        true,
        n.exec_lua(function()
          vim.api.nvim_win_set_cursor(0, { 2, 0 })
          local panel = assert(require('synapse').view())
          return not vim.bo[panel.bufnr].modifiable
        end)
      )
    end
  )

  t.it('opens overlapping threads from Ex ranges, visual keymaps, and Lua ranges', function()
    n.exec_lua(function()
      require('synapse').comment({ file = 'code.lua', line = 2, end_line = 3, body = 'overlap' })
      vim.keymap.set({ 'n', 'x' }, '<leader>st', ':SynapseThread<CR>')
    end)
    n.command('1,2SynapseThread')
    t.matches('overlap', table.concat(n.api.nvim_buf_get_lines(0, 0, -1, false), '\n'))
    n.feed('qggVj\\st')
    t.matches('overlap', table.concat(n.api.nvim_buf_get_lines(0, 0, -1, false), '\n'))
    n.feed('q')
    t.eq(
      true,
      n.exec_lua(function()
        local panel = assert(require('synapse').view({ line = 3, end_line = 4 }))
        return not vim.bo[panel.bufnr].modifiable
      end)
    )
  end)

  t.it('offers each matching thread once and supports choosing or cancelling the picker', function()
    t.eq(
      { { 'c1', 'c3' }, 'c3:2-3 [human] second', true, true, true },
      n.exec_lua(function()
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 1, end_line = 2, body = 'first' })
        s.comment({ parent_id = 'c1', body = 'reply' })
        s.comment({ file = 'code.lua', line = 2, end_line = 3, body = 'second\nmore' })
        s.comment({ file = 'code.lua', line = 4, body = 'outside range' })
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        local win = vim.api.nvim_get_current_win()
        local ids, label
        local function choose(_)
          error('picker was not opened')
        end
        vim.ui.select = function(items, opts, callback)
          ids = vim.tbl_map(function(thread)
            return thread.id
          end, items)
          label = assert(opts.format_item)(items[2])
          choose = function(cancel)
            callback(not cancel and items[2] or nil)
          end
        end
        local result = s.view()
        choose(true)
        local cancelled = vim.api.nvim_get_current_win() == win
        s.view()
        choose(false)
        local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
        return { ids, label, result == nil, cancelled, text:find('second', 1, true) ~= nil }
      end)
    )
  end)

  t.it('notifies without opening a window when no threads overlap', function()
    t.eq(
      { true, true, 'synapse: no threads on these lines' },
      n.exec_lua(function()
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 2, body = 'elsewhere' })
        local win = vim.api.nvim_get_current_win()
        local message
        vim.notify = function(text)
          message = text
        end
        vim.cmd.SynapseThread()
        local result = s.view({ line = 4 })
        return { result == nil, vim.api.nvim_get_current_win() == win, message }
      end)
    )
  end)

  t.it('loads markers for the first agent comment without loading the UI', function()
    local screen = Screen.new(80, 16)
    n.exec_lua(function()
      local s = require('synapse')
      s.setup({ diagnostics = { signs = false, virtual_text = true } })
      require('synapse.agent').dispatch({
        session_id = s.info().session_id,
        op = 'comment',
        args = { file = 'code.lua', line = 2, body = 'first agent comment' },
      })
    end)
    screen:expect({ any = 'first agent comment' })
    t.eq(
      { false, true, false },
      n.exec_lua(function()
        local namespace = vim.api.nvim_get_namespaces().synapse
        return {
          package.loaded['synapse.ui'] ~= nil,
          package.loaded['synapse.markers'] ~= nil,
          assert(vim.diagnostic.config(nil, namespace)).signs,
        }
      end)
    )
  end)

  t.it('cancels drafts without publishing or saving them', function()
    n.command('SynapseComment')
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'unfinished' })
    n.feed('q')
    t.eq(
      { 0, 0 },
      n.exec_lua(function()
        local s = require('synapse')
        return { #s.threads(), #s.saved_sessions() }
      end)
    )
  end)
  t.it('supports omitted composition options and prefills edits with the existing body', function()
    t.eq(
      { 'original', 'second line' },
      n.exec_lua(function()
        local s = require('synapse')
        local draft = s.compose()
        assert(vim.deep_equal({ '' }, vim.api.nvim_buf_get_lines(draft.bufnr, 0, -1, false)))
        vim.api.nvim_buf_delete(draft.bufnr, { force = true })
        local c = s.comment({ file = 'code.lua', line = 1, body = 'original\nsecond line' })
        local edit = s.compose({ id = c.id })
        return vim.api.nvim_buf_get_lines(edit.bufnr, 0, -1, false)
      end)
    )
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'revised' })
    n.feed('<C-s>')
    t.eq('revised', n.exec_lua([[return assert(require('synapse').threads()[1]).comments[1].body]]))
  end)
  t.it(
    'browses whole threads once, filters by any participant, and navigates to recorded code',
    function()
      n.exec_lua(function()
        local s = require('synapse')
        local c = s.comment({ file = 'code.lua', line = 2, end_line = 3, body = 'human root' })
        require('synapse.agent').dispatch({
          session_id = s.info().session_id,
          op = 'comment',
          args = { parent_id = c.id, body = 'agent reply' },
        })
        s.comment({ file = 'code.lua', line = 4, body = 'another root' })
        s.browse('agent')
      end)
      t.eq(
        { 1, 2, 3 },
        n.exec_lua(function()
          local items = vim.fn.getqflist()
          return { #items, items[1].lnum, items[1].end_lnum }
        end)
      )
      n.feed('<CR>')
      n.exec_lua([[vim.cmd.normal('q')]])
      t.eq(
        { project .. '/code.lua', 2 },
        n.exec_lua([[return { vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0)[1] }]])
      )
      n.exec_lua([[require('synapse').browse('human')]])
      t.eq(2, n.exec_lua([[return #vim.fn.getqflist()]]))
    end
  )

  t.it(
    'renders native range markers without entering ordinary diagnostics and restores fixed coordinates after edits',
    function()
      local screen = Screen.new(80, 16)
      n.exec_lua(function()
        vim.diagnostic.config({ virtual_text = true, underline = true, signs = true })
        require('synapse').comment({
          file = 'code.lua',
          line = 2,
          end_line = 3,
          body = 'recorded discussion',
        })
      end)
      screen:expect({ any = 'recorded discussion' })
      t.eq(
        { 0, true, true, 0 },
        n.exec_lua(function()
          local count = #vim.diagnostic.get()
          local no_next = vim.diagnostic.get_next() == nil
          local no_float = vim.diagnostic.open_float() == nil
          vim.diagnostic.setqflist({ open = false })
          return { count, no_next, no_float, #vim.fn.getqflist() }
        end)
      )
      n.api.nvim_buf_set_lines(0, 0, 0, false, { 'inserted' })
      n.exec_lua([[vim.wait(100, function()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
        if assert(mark[4]).sign_hl_group == 'DiagnosticSignHint' and mark[2] == 1 then return true end
      end
    end)]])
      t.eq(
        { 2, 3, 1, 2 },
        n.exec_lua(function()
          local s = require('synapse')
          local a = assert(s.threads()[1]).anchor
          local sign, last
          for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
            if assert(mark[4]).sign_hl_group == 'DiagnosticSignHint' then
              sign = mark[2]
            end
            if assert(mark[4]).hl_group == 'DiagnosticUnderlineHint' then
              last = assert(mark[4]).end_row
            end
          end
          return { a.line, a.end_line, sign, last }
        end)
      )
      vim.fn.delete(project .. '/code.lua')
      t.eq(1, n.exec_lua([[return #require('synapse').threads()]]))
    end
  )
  t.it('keeps only submitted text when restarting with an open draft', function()
    local id = n.exec_lua(function()
      local s = require('synapse')
      s.comment({ file = 'code.lua', line = 1, body = 'submitted' })
      s.compose({ parent_id = 'c1' })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unfinished reply' })
      return s.info().session_id
    end)
    n.expect_exit(n.command, 'qa!')
    n.clear()
    t.eq(
      { 0, 1, 'submitted' },
      n.exec_lua(function(root, saved)
        local s = require('synapse')
        s.setup({ root = root, discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
        local fresh = #s.threads()
        s.resume(saved)
        local thread = assert(s.threads()[1])
        return { fresh, #thread.comments, assert(thread.comments[1]).body }
      end, project, id)
    )
  end)

  t.it('respects disabled diagnostic display facilities while retaining browser entries', function()
    n.exec_lua(function()
      vim.diagnostic.config({
        signs = false,
        underline = false,
        virtual_text = false,
        virtual_lines = false,
      })
      require('synapse').comment({ file = 'code.lua', line = 2, body = 'not a compiler diagnostic' })
    end)
    t.eq(0, #n.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true }))
    t.eq(1, n.exec_lua([[return #require('synapse').browse()]]))
  end)
  t.it(
    'preserves ordinary quickfix Enter behavior when another tool replaces the thread list',
    function()
      n.exec_lua(function(root)
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 1, body = 'thread' })
        s.browse()
        vim.fn.setqflist({}, ' ', {
          title = 'Other tool',
          items = {
            { filename = root .. '/code.lua', lnum = 4, col = 1, text = 'ordinary entry' },
          },
        })
      end, project)
      n.feed('<CR>')
      t.eq(
        { 4, true },
        n.exec_lua(
          [[return { vim.api.nvim_win_get_cursor(0)[1], vim.fn.getqflist({ winid = 0 }).winid ~= 0 }]]
        )
      )
    end
  )
  t.it('restores an existing quickfix Enter mapping after repeated thread browsing', function()
    n.exec_lua(function(root)
      vim.fn.setqflist({}, ' ', { items = { { filename = root .. '/code.lua', lnum = 4 } } })
      vim.cmd.copen()
      vim.keymap.set('n', '<CR>', function()
        vim.g.other_quickfix_enter = true
        vim.cmd.normal({ bang = true, args = { '\r' } })
      end, { buffer = true })
      local s = require('synapse')
      s.comment({ file = 'code.lua', line = 1, body = 'thread' })
      s.browse()
      s.browse('human')
      vim.fn.setqflist(
        {},
        ' ',
        { title = 'Other tool', items = { { filename = root .. '/code.lua', lnum = 4 } } }
      )
    end, project)
    n.feed('<CR>')
    t.eq(
      { true, 4 },
      n.exec_lua([[return { vim.g.other_quickfix_enter, vim.api.nvim_win_get_cursor(0)[1] }]])
    )
  end)
  t.it(
    'rejects stale browser entries before navigating and accepts a fresh list after resumption',
    function()
      local saved = n.exec_lua(function()
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 1, body = 'imported conversation' })
        return s.info().session_id
      end)
      n.clear()
      local code_win = n.exec_lua(function(root, id)
        local s = require('synapse')
        s.setup({ root = root, discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
        vim.cmd.edit(root .. '/code.lua')
        local win = vim.api.nvim_get_current_win()
        s.comment({ file = 'code.lua', line = 3, body = 'destination conversation' })
        s.browse('human')
        s.resume(id, { confirm = true })
        return win
      end, project, saved)
      n.feed('<CR>')
      t.eq(
        { 'quickfix', 1, 0 },
        n.exec_lua(function(win)
          local floats = 0
          for _, window in ipairs(vim.api.nvim_list_wins()) do
            if vim.fn.win_gettype(window) == 'popup' then
              floats = floats + 1
            end
          end
          return { vim.bo.buftype, vim.api.nvim_win_get_cursor(win)[1], floats }
        end, code_win)
      )
      t.matches('SynapseBrowse', n.exec_lua([[return vim.fn.execute('messages')]]))
      n.command('SynapseBrowse human')
      n.feed('<CR>')
      t.eq(
        { false, 1, true },
        n.exec_lua(function(win)
          local transcript = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
          return {
            vim.bo.modifiable,
            vim.api.nvim_win_get_cursor(win)[1],
            transcript:find('imported conversation', 1, true) ~= nil,
          }
        end, code_win)
      )
    end
  )
  for _, action in ipairs({ 'edit', 'reply' }) do
    t.it('retains but rejects a stale ' .. action .. ' draft after resumption', function()
      local saved = n.exec_lua(function()
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 1, body = 'imported conversation' })
        return s.info().session_id
      end)
      n.clear()
      n.exec_lua(function(root, id, mode)
        local s = require('synapse')
        s.setup({ root = root, discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
        s.comment({ file = 'code.lua', line = 3, body = 'destination conversation' })
        s.compose(mode == 'edit' and { id = 'c1' } or { parent_id = 'c1' })
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft for the old destination' })
        s.resume(id, { confirm = true })
      end, project, saved, action)
      n.feed('<C-s>')
      t.eq(
        { 'imported conversation', 1, 1, true, 'draft for the old destination' },
        n.exec_lua(function()
          local thread = assert(require('synapse').threads()[1])
          return {
            assert(thread.comments[1]).body,
            thread.anchor.line,
            #thread.comments,
            vim.bo.modifiable,
            vim.api.nvim_buf_get_lines(0, 0, -1, false)[1],
          }
        end)
      )
    end)
  end
end)
