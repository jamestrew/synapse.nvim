local root = assert(vim.env.SYNAPSE_ROOT, 'Run tests through make test')

-- Functional plugin tests do not need Neovim's generated C/FFI build metadata.
package.preload['test.cmakeconfig.paths'] = function()
  return {
    test_build_dir = vim.fn.getcwd(),
    test_source_path = root .. '/.deps/neovim',
    include_paths = {},
    is_asan = false,
    is_zig_build = false,
    translations_enabled = false,
  }
end

dofile(root .. '/.deps/neovim/test/functional/preload.lua')
local n = require('test.functional.testnvim')()
vim.list_extend(n.nvim_argv, {
  '--cmd',
  ('lua vim.opt.rtp:prepend(%q)'):format(root),
  -- The harness uses -u NONE, which disables automatic plugin loading.
  '--cmd',
  'runtime plugin/synapse.lua',
})
