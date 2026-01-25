local config = require("codex.config")
local util = require("codex.util")
local uv = vim.uv or vim.loop

local M = {}

local function notify(msg, level)
  vim.notify("codex.nvim: " .. msg, level or vim.log.levels.INFO)
end

local function echo(msg, hl)
  vim.api.nvim_echo({ { msg, hl or "ModeMsg" } }, false, {})
end

local function clear_echo()
  vim.cmd("echo ''")
end

local function start_progress(relpath, marks)
  local frames = { "-", "\\", "|", "/" }
  local index = 1
  local timer = uv.new_timer()
  local active = true
  local base = string.format("Codex editing %s:%d-%d ", relpath, marks.s_line, marks.e_line)

  local function render(extra)
    if not active then
      return
    end
    local frame = frames[index]
    index = (index % #frames) + 1
    local suffix = extra and (" " .. extra) or ""
    echo(base .. frame .. suffix)
  end

  render("starting")
  timer:start(120, 120, vim.schedule_wrap(function()
    render(nil)
  end))

  local function stop(final_msg, hl)
    if not active then
      return
    end
    active = false
    if timer and not uv.is_closing(timer) then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      if final_msg and final_msg ~= "" then
        echo(final_msg, hl)
      else
        clear_echo()
      end
    end)
  end

  return {
    render = render,
    stop = stop,
  }
end

local function trim(text)
  if not text then
    return ""
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_visual_marks()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local s_line, s_col = start_pos[2], start_pos[3]
  local e_line, e_col = end_pos[2], end_pos[3]

  if s_line == 0 or e_line == 0 then
    notify("no visual selection found", vim.log.levels.WARN)
    return nil
  end

  if e_line < s_line or (e_line == s_line and e_col < s_col) then
    s_line, e_line = e_line, s_line
    s_col, e_col = e_col, s_col
  end

  return { s_line = s_line, s_col = s_col, e_line = e_line, e_col = e_col }
end

local function selection_mode()
  local mode = vim.fn.visualmode()
  if mode == "\022" then
    notify("blockwise visual selection is not supported", vim.log.levels.WARN)
    return nil
  end
  if mode == "V" then
    return "line"
  end
  return "char"
end

local function cap_content(lines)
  local opts = config.values.selection_edit or {}
  local max_lines = opts.max_lines or 400
  local max_chars = opts.max_chars or 20000

  local capped = {}
  local total_chars = 0
  local truncated = false

  for i, line in ipairs(lines) do
    if i > max_lines then
      truncated = true
      break
    end
    total_chars = total_chars + #line
    if total_chars > max_chars then
      truncated = true
      break
    end
    capped[#capped + 1] = line
  end

  if truncated then
    capped[#capped + 1] = ""
    capped[#capped + 1] = "[...truncated...]"
  end

  return table.concat(capped, "\n"), truncated
end

local function slice_selection(buf, marks, mode)
  local lines = vim.api.nvim_buf_get_lines(buf, marks.s_line - 1, marks.e_line, false)
  if #lines == 0 then
    return {}
  end

  if mode == "line" then
    return lines
  end

  lines[1] = string.sub(lines[1], marks.s_col)
  lines[#lines] = string.sub(lines[#lines], 1, marks.e_col)
  return lines
end

local function context_lines(buf, marks, context_count)
  local total = vim.api.nvim_buf_line_count(buf)
  local before_start = math.max(0, marks.s_line - 1 - context_count)
  local before_end = marks.s_line - 1
  local after_start = marks.e_line
  local after_end = math.min(total, marks.e_line + context_count)

  local before = {}
  local after = {}

  if before_end > before_start then
    before = vim.api.nvim_buf_get_lines(buf, before_start, before_end, false)
  end
  if after_end > after_start then
    after = vim.api.nvim_buf_get_lines(buf, after_start, after_end, false)
  end

  return before, after
end

local function build_instruction(relpath, marks, mode, selection_text, before_text, after_text, user_prompt)
  local mode_label = mode == "line" and "linewise" or "characterwise"
  local range_label = string.format("%s:%d-%d", relpath, marks.s_line, marks.e_line)

  local parts = {
    "Edit the file directly using the available tools.",
    "",
    "Rules:",
    "- Use apply_patch (or other tools) to modify the file on disk.",
    "- Only change the selected range unless the user explicitly asks otherwise.",
    "- Do not ask for confirmation; perform the edit.",
    "- Do not return replacement code. Keep any response extremely brief.",
    "",
    "Target range: " .. range_label,
    "Selection mode: " .. mode_label,
    "",
    "Context before selection:",
    before_text ~= "" and before_text or "(none)",
    "",
    "Selected code:",
    selection_text,
    "",
    "Context after selection:",
    after_text ~= "" and after_text or "(none)",
    "",
    "Edit request:",
    user_prompt,
  }

  return table.concat(parts, "\n")
end

function M.edit_visual_selection()
  local core = require("codex.core")
  local root = core.ensure_context()

  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    notify("current buffer has no file name", vim.log.levels.WARN)
    return
  end

  local marks = get_visual_marks()
  if not marks then
    return
  end

  local mode = selection_mode()
  if not mode then
    return
  end

  local selection_lines = slice_selection(buf, marks, mode)
  local selection_text, truncated = cap_content(selection_lines)

  local context_count = config.values.selection_edit.context_lines or 20
  local before_lines, after_lines = context_lines(buf, marks, context_count)
  local before_text = table.concat(before_lines, "\n")
  local after_text = table.concat(after_lines, "\n")

  vim.cmd("normal! \\<Esc>")

  vim.ui.input({
    prompt = config.values.selection_edit.prompt or "Codex edit> ",
  }, function(input)
    local user_prompt = trim(input)
    if user_prompt == "" then
      return
    end

    local relpath = util.relative(root, path)
    local instruction = build_instruction(relpath, marks, mode, selection_text, before_text, after_text, user_prompt)
    local progress = start_progress(relpath, marks)

    if truncated then
      notify("selection was truncated before sending to Codex", vim.log.levels.WARN)
    end

    core.send(instruction, {
      role = "user",
      callbacks = {
        on_thread_started = function()
          progress.render("running")
        end,
        on_stream = function()
          progress.render("editing")
        end,
        on_error = function()
          progress.stop("Codex edit failed", "ErrorMsg")
        end,
        on_done = function()
          progress.stop("Codex edit complete", "ModeMsg")
          if vim.api.nvim_buf_is_valid(buf) then
            vim.cmd("checktime " .. vim.fn.fnameescape(path))
          end
          notify("Codex edit complete")
        end,
      },
    })
  end)
end

return M
