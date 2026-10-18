local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local project = ''
local clients = {}
local function rpc(client, code, ...)
  local ok, result = client:request('nvim_exec_lua', code, { ... })
  assert(ok, vim.inspect(result))
  return result
end
local function child()
  local client = n.new_session(true)
  clients[#clients + 1] = client
  return client
end
local function server(client, root)
  return rpc(
    client,
    [[local root, live, saved = ...
    return require('synapse').setup({ root = root, discovery_dir = live, storage_dir = saved })
  ]],
    root,
    project .. '/live',
    project .. '/saved'
  )
end

local function request_process(request, timeout)
  local script = project .. '/request.lua'
  vim.fn.writefile({
    'vim.opt.rtp:prepend(assert(vim.env.SYNAPSE_PLUGIN))',
    "local agent = require('synapse.agent')",
    'local request = vim.json.decode(assert(vim.env.SYNAPSE_REQUEST))',
    'local result = request.op and agent.request(request) or agent.discover(request)',
    "io.write(vim.json.encode(result), '\\n')",
  }, script)
  local result = vim
    .system({ vim.env.NVIM_PRG, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', script }, {
      timeout = timeout or 5000,
      env = { SYNAPSE_PLUGIN = vim.env.SYNAPSE_ROOT, SYNAPSE_REQUEST = vim.json.encode(request) },
    })
    :wait()
  t.eq(0, result.code, result.stderr)
  return vim.json.decode(assert(result.stdout))
end

t.describe('documented agent RPC interface', function()
  t.before_each(function()
    project = vim.fn.tempname()
    vim.fn.mkdir(project, 'p')
    vim.fn.writefile({ 'code', 'more' }, project .. '/code.lua')
    n.clear()
  end)
  t.after_each(function()
    for _, client in ipairs(clients) do
      client:close()
    end
    clients = {}
    n.clear()
    vim.fn.delete(project, 'rf')
  end)

  t.it(
    'discovers one live session, ignores stale advertisements, and creates a visible agent thread over RPC',
    function()
      local live = server(child(), project)
      vim.fn.writefile({
        vim.json.encode({
          project_root = project,
          session_id = 'stale',
          socket = project .. '/absent',
        }),
      }, project .. '/live/stale.json')
      t.eq(
        { 'agent', 2, 'over RPC' },
        n.exec_lua(function(root)
          local result = require('synapse.agent').request({
            project_root = root,
            discovery_dir = root .. '/live',
            op = 'comment',
            args = { file = 'code.lua', line = 2, body = 'over RPC' },
          })
          return { result.author, result.anchor.line, result.body }
        end, project)
      )
      t.eq(1, #rpc(clients[1], [[return require('synapse').threads()]]))
      local ad = vim.json.decode(
        table.concat(vim.fn.readfile(project .. '/live/' .. live.session_id .. '.json'), '\n')
      )
      t.eq(project, ad.project_root)
      t.eq(live.socket, ad.socket)
      t.eq(live.session_id, ad.session_id)
      clients[1]:request('nvim_command', 'qa!')
      t.eq(0, vim.fn.filereadable(project .. '/live/' .. live.session_id .. '.json'))
      t.eq(1, vim.fn.filereadable(project .. '/saved/' .. live.session_id .. '.json'))
    end
  )
  t.it(
    'requires selection for same-project sessions and never broadcasts or merges their saved conversations',
    function()
      local first, second = server(child(), project), server(child(), project)
      local elsewhere = project .. '/other'
      vim.fn.mkdir(elsewhere, 'p')
      local other = server(child(), elsewhere)
      rpc(clients[1], [[vim.cmd.cd(...)]], elsewhere)
      t.eq(project, rpc(clients[1], [[return require('synapse').info().project_root]]))
      t.eq(
        'ambiguous',
        n.exec_lua(function(root)
          local ok, err = pcall(require('synapse.agent').request, {
            project_root = root,
            discovery_dir = root .. '/live',
            op = 'comment',
            args = { file = 'code.lua', line = 1, body = 'must not publish' },
          })
          assert(not ok and err:find('ambiguous'))
          return 'ambiguous'
        end, project)
      )
      n.exec_lua(function(root, id)
        require('synapse.agent').request({
          project_root = root,
          discovery_dir = root .. '/live',
          session_id = id,
          op = 'comment',
          args = { file = 'code.lua', line = 1, body = 'only first' },
        })
      end, project, first.session_id)
      t.eq({ 1, 0, 0 }, {
        #rpc(clients[1], [[return require('synapse').threads()]]),
        #rpc(clients[2], [[return require('synapse').threads()]]),
        #rpc(clients[3], [[return require('synapse').threads()]]),
      })
      rpc(
        clients[2],
        [[require('synapse').comment({ file = 'code.lua', line = 2, body = 'only second' })]]
      )
      rpc(
        clients[1],
        [[require('synapse').comment({ parent_id = 'c1', body = 'human reply' }); require('synapse').edit('c2', 'updated first')]]
      )
      t.eq(2, #vim.fn.glob(project .. '/saved/*.json', false, true))
      rpc(
        clients[3],
        [[local id = ...
      local ok, err = pcall(require('synapse').resume, id)
      assert(not ok and err:find('different project'))
    ]],
        first.session_id
      )
      -- A live saved identity is copied rather than taken over by another editor.
      rpc(clients[2], [[require('synapse').resume(..., { confirm = true })]], first.session_id)
      rpc(clients[2], [[require('synapse').edit('c2', 'independent copy')]])
      t.eq(
        'updated first',
        rpc(clients[1], [[return require('synapse').threads()[1].comments[2].body]])
      )
      t.neq(first.session_id, second.session_id)
      t.neq(second.session_id, other.session_id)
    end
  )

  t.it('discovers a Git worktree root from a nested cwd and retains that root after cd', function()
    local function git(args)
      vim.fn.system(vim.list_extend({ 'git', '-C', project }, args))
      assert(vim.v.shell_error == 0)
    end
    git({ 'init', '-q' })
    git({
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.test',
      '-c',
      'commit.gpgsign=false',
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '--allow-empty',
      '-qm',
      'init',
    })
    local worktree = project .. '/worktree'
    git({ 'worktree', 'add', '-q', '--detach', worktree })
    vim.fn.mkdir(worktree .. '/nested', 'p')
    local client = child()
    t.eq(
      worktree,
      rpc(
        client,
        [[local root = ...
      vim.cmd.cd(root .. '/worktree/nested')
      local s = require('synapse')
      s.setup({ discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
      vim.cmd.cd(root)
      return s.info().project_root
    ]],
        project
      )
    )
  end)
  t.it('finds default advertisements across processes without XDG_RUNTIME_DIR', function()
    local client = child()
    local info = rpc(
      client,
      [[local root = ...
      vim.env.XDG_RUNTIME_DIR = nil
      return require('synapse').setup({ root = root, storage_dir = root .. '/saved' })
    ]],
      project
    )
    t.eq(
      info.session_id,
      n.exec_lua(function(root)
        vim.env.XDG_RUNTIME_DIR = nil
        local live = require('synapse.agent').discover({ project_root = root })
        assert(#live == 1, 'expected one discoverable session')
        return live[1].session_id
      end, project)
    )
    client:request('nvim_command', 'qa!')
  end)
  t.it(
    'runs the documented short-lived Neovim client without another executable or setup',
    function()
      server(child(), project)
      local c = request_process({
        project_root = project,
        discovery_dir = project .. '/live',
        op = 'comment',
        args = { file = 'code.lua', line = 1, body = 'from the skill' },
      })
      t.eq('agent', c.author)
      t.eq(
        'from the skill',
        rpc(clients[1], [[return require('synapse').threads()[1].comments[1].body]])
      )
    end
  )
  t.it(
    'targets a healthy session when a peer is paused and bounds automatic liveness probes',
    function()
      local healthy = server(child(), project)
      server(child(), project)
      rpc(
        clients[1],
        [[require('synapse').comment({ file = 'code.lua', line = 1, body = 'healthy' })]]
      )
      local pid = rpc(clients[2], [[return vim.fn.getpid()]])
      assert(vim.uv.kill(pid, 'sigstop') == 0)
      local ok, err = pcall(function()
        -- Explicit identity is filtered before connecting, not after a blocked probe.
        local selected = request_process({
          project_root = project,
          discovery_dir = project .. '/live',
          session_id = healthy.session_id,
          op = 'threads',
          timeout_ms = 5000,
        }, 2000)
        t.eq(1, #selected)
        -- Without a selection the paused process times out and is ineligible.
        local automatic = request_process({
          project_root = project,
          discovery_dir = project .. '/live',
          op = 'threads',
          timeout_ms = 50,
        }, 2000)
        t.eq('healthy', automatic[1].comments[1].body)
      end)
      assert(vim.uv.kill(pid, 'sigcont') == 0)
      assert(ok, err)
    end
  )

  t.it('discovers and resumes snapshots under literal paths containing glob characters', function()
    local root = project .. '/project[abc]'
    vim.fn.mkdir(root, 'p')
    vim.fn.writefile({ 'code' }, root .. '/code.lua')
    local client = child()
    local info = rpc(
      client,
      [[local root = ...
      local s = require('synapse')
      local info = s.setup({ root = root, discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
      s.comment({ file = 'code.lua', line = 1, body = 'literal path' })
      assert(#s.saved_sessions() == 1)
      return info
    ]],
      root
    )
    t.eq(1, #request_process({ project_root = root, discovery_dir = root .. '/live' }))
    local copy = child()
    t.eq(
      'literal path',
      rpc(
        copy,
        [[local root, id = ...
      local s = require('synapse')
      s.setup({ root = root, discovery_dir = root .. '/live', storage_dir = root .. '/saved' })
      s.resume(id)
      return s.threads()[1].comments[1].body
    ]],
        root,
        info.session_id
      )
    )
  end)
end)
