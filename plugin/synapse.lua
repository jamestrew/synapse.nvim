if vim.g.loaded_synapse then
  return
end
vim.g.loaded_synapse = true

local group = vim.api.nvim_create_augroup('synapse.bootstrap', { clear = true })
vim.api.nvim_create_autocmd('User', {
  group = group,
  pattern = 'SynapseChanged',
  once = true,
  callback = function()
    require('synapse').refresh()
  end,
})

vim.api.nvim_create_user_command('SynapseDelete', function(args)
  require('synapse').delete(args.args)
end, { nargs = 1 })

vim.api.nvim_create_user_command('SynapseClear', function(args)
  local scope = args.bang and 'ALL human and agent comments' or 'agent comments'
  if vim.fn.confirm('Clear ' .. scope .. '?', '&Yes\n&No', 2) == 1 then
    require('synapse').clear({ confirm = true, include_human = args.bang })
  end
end, { bang = true })

vim.api.nvim_create_user_command('SynapseResume', function(args)
  require('synapse').resume(args.args)
end, {
  nargs = 1,
  complete = function()
    return vim.tbl_map(function(saved)
      return saved.session_id
    end, require('synapse').saved_sessions())
  end,
})

vim.api.nvim_create_user_command('SynapseComment', function(args)
  require('synapse').compose({ line = args.line1, end_line = args.line2 })
end, { range = true })

vim.api.nvim_create_user_command('SynapseBrowse', function(args)
  local author = args.args ~= '' and args.args or nil
  assert(author == nil or author == 'human' or author == 'agent', 'synapse: invalid author filter')
  require('synapse').browse(author)
end, {
  nargs = '?',
  complete = function()
    return { 'human', 'agent' }
  end,
})

vim.api.nvim_create_user_command('SynapseThread', function(args)
  require('synapse').view(
    args.args ~= '' and args.args or { line = args.line1, end_line = args.line2 }
  )
end, { nargs = '?', range = true })

vim.api.nvim_create_user_command('SynapseReply', function(args)
  require('synapse').compose({ parent_id = args.args })
end, { nargs = 1 })

vim.api.nvim_create_user_command('SynapseEdit', function(args)
  require('synapse').compose({ id = args.args })
end, { nargs = 1 })
