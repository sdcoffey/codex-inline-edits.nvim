local config = require("codex.config")

local M = {
  _did_setup = false,
}

function M.setup(opts)
  config.setup(opts)

  if not M._did_setup then
    require("codex.commands").setup_commands()
    require("codex.commands").setup_keymaps()
    M._did_setup = true
  end

  require("codex.sync").restart()
  require("codex.core").ensure_context()
end

return M
