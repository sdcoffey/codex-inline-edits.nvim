# codex.nvim

Inline, selection-based editing with Codex for Neovim.

## Install (lazy.nvim)

```lua
{
  "sdcoffey/codex.nvim",
  build = "npm install",
  config = function()
    require("codex").setup()
  end,
}
```

## Usage

1. Visually select the code you want to change.
2. Run `:CodexEditSelection`.
3. Enter your instruction. Codex edits the file directly and the buffer refreshes on completion.

## Commands

- `:CodexEditSelection` edits the current (or most recent) visual selection.

## Keymaps

This plugin does not define keymaps. A typical mapping looks like:

```lua
vim.keymap.set("v", "<leader>cr", "<cmd>CodexEditSelection<cr>", { desc = "Codex: edit selection" })
```

## Configuration

```lua
require("codex").setup({
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
    cmd = { "node", "/path/to/codex.nvim/bridge/codex-bridge.mjs" },
    cwd = "/path/to/codex.nvim",
    env = {},
    codex_path = nil,
    model = "gpt-5.2-codex",
    thread_options = {
      sandboxMode = "workspace-write",
      skipGitRepoCheck = true,
      approvalPolicy = "on-request",
    },
  },
})
```
