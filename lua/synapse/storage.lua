local M = {}

---@param path string
---@return any Decoded JSON; callers validate its shape at the trust boundary.
function M.read(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

---Enumerate literal directories, including names containing glob metacharacters.
---@param directory string
---@return string[]
function M.files(directory)
  local paths = {}
  if vim.fn.isdirectory(directory) == 0 then
    return paths
  end
  for name, kind in vim.fs.dir(directory) do
    if kind == 'file' and name:match('%.json$') then
      paths[#paths + 1] = vim.fs.joinpath(directory, name)
    end
  end
  table.sort(paths)
  return paths
end

---Replace one snapshot atomically; failures leave the previous snapshot intact.
---@param path string
---@param value any JSON-serializable data.
---@return nil
function M.write(path, value)
  local temporary = path .. '.' .. vim.fn.getpid() .. '.' .. tostring(vim.uv.hrtime()) .. '.tmp'
  ---@type integer?
  local fd
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), 'p', '448')
    fd = assert(vim.uv.fs_open(temporary, 'wx', 384))
    local encoded = vim.json.encode(value) .. '\n'
    assert(vim.uv.fs_write(fd, encoded, 0) == #encoded, 'incomplete write')
    assert(vim.uv.fs_fsync(fd))
    assert(vim.uv.fs_close(fd))
    fd = nil
    assert(vim.uv.fs_rename(temporary, path))
  end)
  if fd then
    vim.uv.fs_close(fd)
  end
  if not ok then
    vim.uv.fs_unlink(temporary)
    error('synapse: save failed: ' .. tostring(err))
  end
end

return M
