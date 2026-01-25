local config = require("codex.config")
local state = require("codex.state")
local util = require("codex.util")
local uv = vim.uv or vim.loop

local M = {}

local function checktime_all()
  vim.cmd("checktime")
end

function M.start()
  if not config.values.sync.enabled then
    return
  end
  if state.sync.enabled then
    return
  end

  local group = vim.api.nvim_create_augroup("CodexSync", { clear = true })
  local debounced, timer = util.debounce(config.values.sync.debounce_ms, checktime_all)

  for _, event in ipairs(config.values.sync.checktime_events) do
    vim.api.nvim_create_autocmd(event, {
      group = group,
      callback = debounced,
      desc = "codex.nvim: refresh changed files",
    })
  end

  state.sync.enabled = true
  state.sync.checktime = debounced
  state.sync.augroup = group
  state.sync.timer = timer
end

function M.stop()
  if state.sync.timer then
    state.sync.timer:stop()
    if not uv.is_closing(state.sync.timer) then
      state.sync.timer:close()
    end
  end
  if state.sync.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.sync.augroup)
  end
  state.sync.enabled = false
  state.sync.augroup = nil
  state.sync.checktime = nil
  state.sync.timer = nil
end

function M.restart()
  M.stop()
  M.start()
end

return M
