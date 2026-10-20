local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local project = ''
local function setup()
  n.exec_lua(function(root)
    require('synapse').setup({
      root = root,
      discovery_dir = root .. '/live',
      storage_dir = root .. '/saved',
    })
  end, project)
end

t.describe('code-anchored conversations', function()
  t.before_each(function()
    project = vim.fn.tempname()
    vim.fn.mkdir(project, 'p')
    vim.fn.writefile({ 'one', 'two', 'three', 'four' }, project .. '/code.lua')
    n.clear()
    setup()
  end)
  t.after_each(function()
    n.clear()
    vim.fn.delete(project, 'rf')
  end)

  t.it('creates a multiline human comment on a working-file range', function()
    t.eq(
      { 'human', 'code.lua', 2, 3, 'why?\nmore context', 1 },
      n.exec_lua(function()
        local s = require('synapse')
        local c =
          s.comment({ file = 'code.lua', line = 2, end_line = 3, body = 'why?\nmore context' })
        local threads = s.threads()
        return { c.author, c.anchor.file, c.anchor.line, c.anchor.end_line, c.body, #threads }
      end)
    )
  end)
  t.it('keeps replies anchored and preserves identity and context when editing', function()
    t.eq(
      { 'c1', 'c1', 'agent', 2, 'clarified', 2, 'human' },
      n.exec_lua(function()
        local s = require('synapse')
        local c = s.comment({ file = 'code.lua', line = 2, body = 'question' })
        local reply = require('synapse.agent').dispatch({
          session_id = s.info().session_id,
          op = 'comment',
          args = { parent_id = c.id, body = 'answer' },
        })
        s.edit(c.id, 'clarified')
        local thread = assert(s.threads('agent')[1])
        return {
          thread.id,
          reply.parent_id,
          reply.author,
          reply.anchor.line,
          assert(thread.comments[1]).body,
          #thread.comments,
          assert(thread.comments[1]).author,
        }
      end)
    )
  end)
  t.it(
    'rejects invalid mutations atomically and preserves parent integrity when clearing',
    function()
      t.eq(
        { true, true, true, 0 },
        n.exec_lua(function()
          local s = require('synapse')
          local function agent(op, args)
            return require('synapse.agent').dispatch({
              session_id = s.info().session_id,
              op = op,
              args = args,
            })
          end
          local a = agent('comment', { file = 'code.lua', line = 1, body = 'observation' })
          local h = s.comment({ parent_id = a.id, body = 'human reply' })
          local function rejected(fn)
            local before = s.threads()
            local ok = pcall(fn)
            assert(not ok)
            assert(vim.deep_equal(before, s.threads()))
          end
          for _, args in ipairs({
            { file = '../outside', line = 1, body = 'bad' },
            { file = 'code.lua', line = 0, body = 'bad' },
            { file = 'code.lua', line = 1, end_line = 9, body = 'bad' },
            { parent_id = 'missing', body = 'bad' },
            { parent_id = a.id, file = 'code.lua', body = 'retarget' },
            { file = 'code.lua', line = 1, body = ' ', author = 'human' },
          }) do
            rejected(function()
              agent('comment', args)
            end)
          end
          rejected(function()
            s.edit(a.id, 'impersonate')
          end)
          rejected(function()
            agent('delete', { id = a.id })
          end)
          rejected(function()
            agent('clear', { confirm = true })
          end)
          rejected(function()
            agent('clear', { include_human = true })
          end)
          rejected(function()
            agent('clear', { confirm = true, include_human = true, file = 'code.lua' })
          end)
          rejected(function()
            require('synapse.agent').dispatch({
              session_id = 'other',
              op = 'clear',
              args = { confirm = true, include_human = true },
            })
          end)
          agent('delete', { id = h.id })
          local deleted_human = #assert(s.threads()[1]).comments == 1
          agent('clear', { confirm = true })
          local default_cleared = #s.threads() == 0
          s.comment({ file = 'code.lua', line = 2, body = 'keep me' })
          agent('clear', { confirm = true })
          local kept_human = #s.threads() == 1
          agent('clear', { confirm = true, include_human = true })
          return { deleted_human, default_cleared, kept_human, #s.threads() }
        end)
      )
    end
  )
  t.it(
    'saves accepted changes across restarts and only resumes explicitly into an independent session',
    function()
      local saved = n.exec_lua(function()
        local s = require('synapse')
        local a = s.comment({ file = 'code.lua', line = 3, body = 'old' })
        local b = s.comment({ parent_id = a.id, body = 'reply' })
        s.edit(a.id, 'revised')
        s.delete(b.id)
        return s.info().session_id
      end)
      n.expect_exit(n.command, 'qa!')
      n.clear()
      setup()
      t.eq(0, n.exec_lua([[return #require('synapse').threads()]]))
      t.eq(
        { true, 'revised', 1, 3 },
        n.exec_lua(function(id)
          local s = require('synapse')
          assert(#s.saved_sessions() == 1)
          s.resume(id)
          local thread = assert(s.threads()[1])
          return {
            s.info().session_id ~= id,
            assert(thread.comments[1]).body,
            #thread.comments,
            thread.anchor.line,
          }
        end, saved)
      )
      n.exec_lua([[require('synapse').clear({ confirm = true, include_human = true })]])
      local cleared = n.exec_lua([[return require('synapse').info().session_id]])
      n.expect_exit(n.command, 'qa!')
      n.clear()
      setup()
      t.eq(
        0,
        n.exec_lua(function(id)
          require('synapse').resume(id)
          return #require('synapse').threads()
        end, cleared)
      )
    end
  )

  t.it('resumes the latest valid project snapshot by default and still accepts an ID', function()
    n.exec_lua(function(root)
      local s = require('synapse')
      local storage = require('synapse.storage')
      local function snapshot(digit, body, modified, project_root)
        local id = digit:rep(24)
        local path = root .. '/saved/' .. id .. '.json'
        storage.write(path, {
          version = 1,
          session_id = id,
          project_root = project_root or root,
          next_id = 2,
          comments = {
            {
              id = 'c1',
              author = 'human',
              body = body,
              anchor = { file = 'code.lua', line = 1, end_line = 1 },
            },
          },
        })
        assert(vim.uv.fs_utime(path, modified, modified))
        return id
      end
      local older = snapshot('2', 'older', 200.25)
      snapshot('1', 'latest', 200.75)
      snapshot('3', 'other project', 300, root .. '/other')
      snapshot('4', ' ', 400)
      vim.cmd.SynapseResume()
      assert(s.threads()[1].comments[1].body == 'latest')
      assert(s.info().session_id ~= ('1'):rep(24))
      local ok, err = pcall(vim.cmd.SynapseResume)
      assert(not ok and tostring(err):find('requires confirm=true'))
      s.clear({ confirm = true, include_human = true })
      vim.cmd.SynapseResume(older)
      assert(s.threads()[1].comments[1].body == 'older')
      assert(s.resume(nil, { confirm = true }).generation == 3)
    end, project)
  end)

  t.it('reports when there is no snapshot to resume without changing the session', function()
    n.exec_lua(function()
      local s = require('synapse')
      local before = s.info()
      local ok, err = pcall(vim.cmd.SynapseResume)
      assert(not ok and tostring(err):find('no saved sessions for this project'))
      assert(vim.deep_equal(before, s.info()))
      assert(#s.threads() == 0)
    end)
  end)

  t.it(
    'surfaces a failed save without changing accepted or previously saved conversations',
    function()
      local saved = n.exec_lua(function()
        local s = require('synapse')
        s.comment({ file = 'code.lua', line = 1, body = 'durable' })
        return s.info().session_id
      end)
      vim.fn.rename(project .. '/saved', project .. '/backup')
      vim.fn.writefile({ 'not a directory' }, project .. '/saved')
      t.matches(
        'save failed',
        n.exec_lua(function()
          local s = require('synapse')
          local ok, err = pcall(s.edit, 'c1', 'not saved')
          assert(not ok)
          assert(assert(assert(s.threads()[1]).comments[1]).body == 'durable')
          return err
        end)
      )
      vim.fn.delete(project .. '/saved')
      vim.fn.rename(project .. '/backup', project .. '/saved')
      n.clear()
      setup()
      t.eq(
        'durable',
        n.exec_lua(function(id)
          local s = require('synapse')
          s.resume(id)
          return assert(assert(s.threads()[1]).comments[1]).body
        end, saved)
      )
    end
  )
  t.it('publishes locally without starting an agent or sending RPC notifications', function()
    n.api.nvim_set_client_info('external agent', {}, 'remote', {}, {})
    local channels = n.api.nvim_list_chans()
    n.exec_lua(
      [[require('synapse').comment({ file = 'code.lua', line = 1, body = 'wait for my handoff' })]]
    )
    t.eq(channels, n.api.nvim_list_chans())
    t.eq(nil, assert(n.get_session()):next_message(30))
  end)

  t.it('rejects corrupt saved parents without replacing a live conversation', function()
    local saved = n.exec_lua(function()
      local s = require('synapse')
      s.comment({ file = 'code.lua', line = 1, body = 'keep' })
      return s.info().session_id
    end)
    local path = project .. '/saved/' .. saved .. '.json'
    local snapshot = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    snapshot.comments[1].parent_id = 'missing'
    vim.fn.writefile({ vim.json.encode(snapshot) }, path)
    t.eq(
      'keep',
      n.exec_lua(function(id)
        local s = require('synapse')
        local ok, err = pcall(s.resume, id, { confirm = true })
        assert(not ok and err:find('invalid saved parent'))
        return assert(assert(s.threads()[1]).comments[1]).body
      end, saved)
    )
  end)
  t.it('rejects working-file anchors escaping the root through a symlink', function()
    local outside = project .. '-outside'
    vim.fn.mkdir(outside, 'p')
    assert(vim.uv.fs_symlink(outside, project .. '/linked', { dir = true }))
    local ok, result = pcall(n.exec_lua, function(root)
      vim.cmd.edit(root .. '/linked/new.lua')
      local s = require('synapse')
      local accepted, err = pcall(function()
        s.comment({ file = 'linked/new.lua', line = 1, body = 'outside project' })
      end)
      assert(not accepted and tostring(err):find('inside the project root'))
      return #s.threads()
    end, project)
    vim.fn.delete(outside, 'rf')
    assert(ok, result)
    t.eq(0, result)
  end)
end)
