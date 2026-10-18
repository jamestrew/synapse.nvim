local M = {}
local api = vim.api
local session = require('synapse.session')
local namespace = api.nvim_create_namespace('synapse')
local attached, pending = {}, {}

local function render(buf)
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.diagnostic.hide(namespace, buf)
  local name = api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return
  end
  name = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
  local info = session.info()
  local count = api.nvim_buf_line_count(buf)
  local diagnostics = {}
  for _, thread in ipairs(session.threads()) do
    local a = thread.anchor
    if vim.fs.joinpath(info.project_root, a.file) == name and a.line <= count then
      local last = math.min(a.end_line, count)
      local text = api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ''
      diagnostics[#diagnostics + 1] = {
        bufnr = buf,
        namespace = namespace,
        lnum = a.line - 1,
        col = 0,
        end_lnum = last - 1,
        end_col = #text,
        severity = vim.diagnostic.severity.HINT,
        source = 'synapse',
        message = assert(thread.comments[1]).body,
      }
    end
  end
  -- Display-only diagnostics never enter Neovim's diagnostic store.
  vim.diagnostic.show(namespace, buf, diagnostics)
  if not attached[buf] then
    attached[buf] = api.nvim_buf_attach(buf, false, {
      on_lines = function()
        if pending[buf] then
          return
        end
        pending[buf] = true
        vim.schedule(function()
          pending[buf] = nil
          render(buf)
        end)
      end,
      on_detach = function()
        attached[buf] = nil
      end,
    })
  end
end

function M.refresh()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    render(buf)
  end
end

function M.setup(opts)
  if opts then
    vim.diagnostic.config(opts, namespace)
  end
  local group = api.nvim_create_augroup('synapse.markers', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'InsertLeave' }, {
    group = group,
    -- Run after native deferred displays, which have no stored diagnostics to restore.
    callback = function()
      vim.schedule(M.refresh)
    end,
  })
  api.nvim_create_autocmd(
    'User',
    { group = group, pattern = 'SynapseChanged', callback = M.refresh }
  )
  M.refresh()
end

return M
