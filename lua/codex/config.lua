local util = require("codex.util")

local M = {}

local plugin_root = util.plugin_root()

local default_config = {
  selection_edit = {
    context_lines = 20,
    prompt = "Codex edit> ",
    max_lines = 400,
    max_chars = 20000,
  },
  sync = {
    enabled = true,
    checktime_events = { "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" },
    debounce_ms = 200,
  },
  backend = {
    cmd = { "node", plugin_root .. "/bridge/codex-bridge.mjs" },
    cwd = plugin_root,
    env = {},
    codex_path = nil,
    model = nil,
    thread_options = {
      sandboxMode = "workspace-write",
      skipGitRepoCheck = true,
      approvalPolicy = "on-request",
    },
  },
}

M.values = vim.deepcopy(default_config)

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts or {})
end

return M
