vim.opt.rtp:prepend(vim.fn.getcwd())

local synapse = require('synapse')
assert(type(synapse.setup) == 'function', 'synapse.setup must be callable')
synapse.setup()

print('synapse.nvim: smoke test passed')
