local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

t.describe('synapse.nvim bootstrap', function()
  t.before_each(n.clear)

  t.it(
    'registers commands and the bootstrap listener once without initializing the plugin',
    function()
      t.eq(
        { false, false, false, false, false },
        n.exec_lua(function()
          for _, name in ipairs({
            'Comment',
            'Browse',
            'Thread',
            'Reply',
            'Edit',
            'Delete',
            'Clear',
            'Resume',
          }) do
            assert(rawget(vim.api.nvim_get_commands({}), 'Synapse' .. name), name)
          end
          local listener = vim.api.nvim_get_autocmds({ group = 'synapse.bootstrap' })
          assert(#listener == 1 and listener[1].pattern == 'SynapseChanged' and listener[1].once)
          vim.cmd('runtime plugin/synapse.lua')
          assert(
            vim.deep_equal(listener, vim.api.nvim_get_autocmds({ group = 'synapse.bootstrap' }))
          )
          return {
            package.loaded.synapse ~= nil,
            package.loaded['synapse.session'] ~= nil,
            package.loaded['synapse.storage'] ~= nil,
            package.loaded['synapse.ui'] ~= nil,
            package.loaded['synapse.markers'] ~= nil,
          }
        end)
      )
    end
  )

  t.it('loads the plugin and calls setup', function()
    t.eq(
      'function',
      n.exec_lua(function()
        return type(require('synapse').setup)
      end)
    )
    n.exec_lua([[require('synapse').setup()]])
  end)

  t.it('exposes the full API without loading implementation modules', function()
    t.eq(
      { false, false, false, false },
      n.exec_lua(function()
        local s = require('synapse')
        for _, name in ipairs({
          'setup',
          'browse',
          'refresh',
          'compose',
          'view',
          'info',
          'threads',
          'edit',
          'delete',
          'clear',
          'saved_sessions',
          'resume',
          'comment',
        }) do
          assert(type(s[name]) == 'function', name)
        end
        return {
          package.loaded['synapse.session'] ~= nil,
          package.loaded['synapse.storage'] ~= nil,
          package.loaded['synapse.ui'] ~= nil,
          package.loaded['synapse.markers'] ~= nil,
        }
      end)
    )
  end)

  t.it('publishes the session without loading UI or markers', function()
    t.eq(
      { true, true, false, false },
      n.exec_lua(function()
        local s = require('synapse')
        local info = s.setup()
        assert(info.session_id == s.info().session_id)
        vim.api.nvim_exec_autocmds('BufEnter', { modeline = false })
        vim.api.nvim_exec_autocmds('InsertLeave', { modeline = false })
        return {
          vim.fn.filereadable(info.discovery_dir .. '/' .. info.session_id .. '.json') == 1,
          #s.threads() == 0,
          package.loaded['synapse.ui'] ~= nil,
          package.loaded['synapse.markers'] ~= nil,
        }
      end)
    )
  end)

  t.it('initializes markers on explicit refresh and retains diagnostic options', function()
    t.eq(
      { false, false, true, true },
      n.exec_lua(function()
        local s = require('synapse')
        s.setup({ diagnostics = { signs = false } })
        s.setup({ diagnostics = { virtual_text = false } })
        s.setup()
        assert(not pcall(s.setup, { diagnostics = 'invalid' }))
        s.refresh()
        local namespace = vim.api.nvim_get_namespaces().synapse
        local signs = assert(vim.diagnostic.config(nil, namespace)).signs
        s.setup({ diagnostics = { signs = true } })
        return {
          signs,
          package.loaded['synapse.ui'] ~= nil,
          package.loaded['synapse.markers'] ~= nil,
          assert(vim.diagnostic.config(nil, namespace)).signs,
        }
      end)
    )
  end)

  t.it('isolates child Neovim state', function()
    n.exec_lua([[vim.g.synapse_test = true]])
    n.clear()
    t.eq(false, n.exec_lua([[return vim.g.synapse_test ~= nil]]))
  end)

  t.it('can assert rendered UI', function()
    local screen = Screen.new(30, 5)
    n.command('set laststatus=0 noruler noshowcmd')
    n.api.nvim_buf_set_lines(0, 0, -1, false, { 'synapse.nvim' })
    screen:expect({ any = 'synapse.nvim' })
  end)
end)
