local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

t.describe('synapse.nvim bootstrap', function()
  t.before_each(n.clear)

  t.it('loads the plugin and calls setup', function()
    t.eq(
      'function',
      n.exec_lua(function()
        return type(require('synapse').setup)
      end)
    )
    n.exec_lua([[require('synapse').setup()]])
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
