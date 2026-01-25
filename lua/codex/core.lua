local util = require("codex.util")
local state = require("codex.state")
local backend = require("codex.backend.sdk")

local M = {}

math.randomseed(util.now())

local function notify(msg, level)
  vim.notify("codex.nvim: " .. msg, level or vim.log.levels.INFO)
end

local function ensure_backend()
  if state.backend then
    return state.backend
  end
  state.backend = backend
  state.backend.start_session({ root = state.root })
  return state.backend
end

function M.root()
  return util.project_root()
end

function M.ensure_context()
  local root = M.root()
  state.ensure_root(root)
  ensure_backend()
  return root
end

local function new_session(root)
  local now = util.now()
  return {
    id = util.uuid4(),
    thread_id = nil,
    root = root,
    created_at = now,
    updated_at = now,
  }
end

function M.ensure_active_session()
  local root = M.ensure_context()

  if state.session and state.session.root == root then
    return state.session
  end

  state.session = new_session(root)
  state.backend.start_session(state.session)
  return state.session
end

local function adopt_thread_id(thread_id)
  if not thread_id or not state.session then
    return
  end
  state.session.thread_id = thread_id
  state.session.updated_at = util.now()
end

local function append_user_message(content, opts)
  opts = opts or {}
  local session = M.ensure_active_session()
  local message = {
    role = opts.role or "user",
    content = content,
    meta = opts.meta,
    ts = util.now(),
  }
  session.updated_at = message.ts
  return session, message
end

function M.handle_touched_files(files, root)
  if not files or vim.tbl_isempty(files) then
    return
  end
  for _, file in ipairs(files) do
    local path = file
    if root and root ~= "" and not util.is_absolute(file) then
      path = root .. "/" .. file
    end
    vim.cmd("checktime " .. vim.fn.fnameescape(path))
  end
end

function M.send(content, opts)
  opts = opts or {}

  local session, message = append_user_message(content, opts)
  local session_root = session.root
  local user_callbacks = opts.callbacks or {}

  local function call_user(name, payload)
    local cb = user_callbacks[name]
    if not cb then
      return
    end
    local ok, err = pcall(cb, payload)
    if not ok then
      notify("callback error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  state.backend.send_message(session, message, {
    on_thread_started = function(thread_id)
      adopt_thread_id(thread_id)
      call_user("on_thread_started", thread_id)
    end,
    on_stream = function(delta)
      adopt_thread_id(delta.thread_id)
      call_user("on_stream", delta)
    end,
    on_response = function(response)
      adopt_thread_id(response.thread_id)
      M.handle_touched_files(response.touched_files, session_root)
      call_user("on_response", response)
    end,
    on_error = function(err)
      local message_text = err and err.message or "Codex backend error"
      notify(message_text, vim.log.levels.ERROR)
      call_user("on_error", err)
    end,
    on_done = function()
      call_user("on_done", nil)
    end,
  })
end

return M
