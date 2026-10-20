local M = {}
local markers_initialized = false

local function ui()
  local module = require('synapse.ui')
  module.setup()
  return module
end

---@param opts? synapse.SetupOpts
---@return synapse.Info
function M.setup(opts)
  -- Session identity and discovery must be ready before an agent connects.
  local info = require('synapse.session').setup(opts)
  if opts and opts.diagnostics then
    vim.diagnostic.config(opts.diagnostics, vim.api.nvim_create_namespace('synapse'))
  end
  if markers_initialized then
    require('synapse.markers').refresh()
  end
  return info
end

---@param author? synapse.Author
---@return vim.quickfix.entry[]
function M.browse(author)
  return ui().browse(author)
end

---@return nil
function M.refresh()
  local markers = require('synapse.markers')
  if not markers_initialized then
    markers.setup()
    markers_initialized = true
  else
    markers.refresh()
  end
end

---@param opts? synapse.ComposeOpts
---@return synapse.Window
function M.compose(opts)
  return ui().compose(opts)
end

---@param target? string|synapse.ViewOpts
---@return synapse.Window?
function M.view(target)
  return ui().view(target)
end

---@return synapse.Info
function M.info()
  return require('synapse.session').info()
end

---@param author? synapse.Author
---@return synapse.Thread[]
function M.threads(author)
  return require('synapse.session').threads(author)
end

---@param id string
---@param body string
---@return synapse.Comment
function M.edit(id, body)
  return require('synapse.session').edit(id, body)
end

---@param id string
---@return true
function M.delete(id)
  return require('synapse.session').delete(id)
end

---@param opts synapse.ClearOpts
---@return integer
function M.clear(opts)
  return require('synapse.session').clear(opts)
end

---@return synapse.SavedSession[]
function M.saved_sessions()
  return require('synapse.session').saved_sessions()
end

---@param id? string Defaults to the project's most recently saved snapshot.
---@param opts? synapse.ResumeOpts
---@return synapse.Info
function M.resume(id, opts)
  return require('synapse.session').resume(id, opts)
end

---@param args synapse.CommentInput
---@return synapse.Comment
function M.comment(args)
  return require('synapse.session').comment(args, 'human')
end

return M
