local M = {
  root = nil,
  session = nil,
  backend = nil,
  sync = {
    enabled = false,
    checktime = nil,
    augroup = nil,
    timer = nil,
  },
}

function M.ensure_root(root)
  if M.root == root then
    return false
  end
  M.root = root
  M.session = nil
  return true
end

return M
