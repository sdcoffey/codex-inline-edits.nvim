local M = {}

function M.setup_commands()
  vim.api.nvim_create_user_command("CodexEditSelection", function()
    require("codex.edit").edit_visual_selection()
  end, {
    desc = "Edit visual selection with Codex",
    range = true,
  })
end

function M.setup_keymaps()
  -- Intentionally a no-op. Users should define their own mappings.
end

return M
