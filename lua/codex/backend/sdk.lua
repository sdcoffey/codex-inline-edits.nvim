local config = require("codex.config")
local state = require("codex.state")
local util = require("codex.util")

local M = {}

local job_id = nil
local running = false
local pending = nil
local queue = {}
local stdout_buffer = ""

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function job_valid(id)
  return id and vim.fn.jobwait({ id }, 0)[1] == -1
end

local function copy_env()
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    env[key] = value
  end
  return env
end

local function backend_config()
  return config.values.backend or {}
end

local function merged_env()
  local backend = backend_config()
  local env = copy_env()
  for key, value in pairs(backend.env or {}) do
    env[key] = tostring(value)
  end
  if backend.codex_path and backend.codex_path ~= "" then
    env.CODEX_PATH_OVERRIDE = backend.codex_path
  end
  return env
end

local function build_thread_options(session)
  local backend = backend_config()
  local thread_options = vim.deepcopy(backend.thread_options or {})
  thread_options.workingDirectory = session.root or state.root
  return thread_options
end

local function ensure_job()
  if job_valid(job_id) then
    return true
  end

  local backend = backend_config()
  local cmd = backend.cmd
  if not cmd or #cmd == 0 then
    notify("codex.nvim: backend.cmd is not configured", vim.log.levels.ERROR)
    return false
  end

  stdout_buffer = ""

  job_id = vim.fn.jobstart(cmd, {
    cwd = backend.cwd,
    env = merged_env(),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      if stdout_buffer ~= "" and data[1] then
        data[1] = stdout_buffer .. data[1]
        stdout_buffer = ""
      end

      local last = data[#data]
      local has_partial = last ~= ""
      local limit = has_partial and (#data - 1) or #data

      for index = 1, limit do
        local line = data[index]
        if line and line ~= "" then
          local ok, decoded = pcall(vim.json.decode, line)
          if ok and decoded then
            M._handle_event(decoded)
          else
            notify("codex.nvim: failed to parse bridge output: " .. line, vim.log.levels.WARN)
          end
        end
      end

      if has_partial then
        stdout_buffer = last
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      local chunks = {}
      for _, line in ipairs(data) do
        if line and line ~= "" then
          table.insert(chunks, line)
        end
      end
      if #chunks > 0 then
        notify("codex.nvim bridge stderr: " .. table.concat(chunks, " | "), vim.log.levels.WARN)
      end
    end,
    on_exit = function(_, code)
      local exit_code = code or -1
      if exit_code ~= 0 and exit_code ~= 143 then
        notify("codex.nvim: SDK bridge exited with code " .. tostring(exit_code), vim.log.levels.ERROR)
      end
      job_id = nil
      stdout_buffer = ""
      if pending then
        local callbacks = pending.callbacks or {}
        if callbacks.on_error then
          callbacks.on_error({ message = "SDK bridge exited" })
        end
        if callbacks.on_done then
          callbacks.on_done()
        end
        pending = nil
      end
      running = false
    end,
  })

  if job_id <= 0 then
    notify("codex.nvim: failed to start SDK bridge", vim.log.levels.ERROR)
    job_id = nil
    return false
  end

  return true
end

local function send_request(request)
  if not ensure_job() then
    return false
  end
  local payload = vim.json.encode(request) .. "\n"
  local ok = vim.fn.chansend(job_id, payload)
  return ok ~= -1
end

local function finish_pending()
  pending = nil
  running = false
  vim.schedule(function()
    M._pump()
  end)
end

local function table_keys(tbl)
  local keys = {}
  for key, value in pairs(tbl or {}) do
    if value then
      table.insert(keys, key)
    end
  end
  table.sort(keys)
  return keys
end

function M._handle_event(event)
  if not pending then
    return
  end
  if event.sessionId ~= pending.session_id then
    return
  end

  local callbacks = pending.callbacks or {}

  if event.type == "thread.started" then
    pending.thread_id = event.threadId
    if callbacks.on_thread_started then
      callbacks.on_thread_started(event.threadId)
    end
    return
  end

  if event.type == "assistant.delta" then
    local next_text = event.text or pending.last_text or ""
    local next_item_id = event.itemId or pending.last_item_id

    if next_text == (pending.last_text or "") and next_item_id == pending.last_item_id then
      return
    end

    pending.last_text = next_text
    pending.last_item_id = next_item_id
    if callbacks.on_stream then
      callbacks.on_stream({
        role = "assistant",
        content = pending.last_text,
        ts = util.now(),
        touched_files = {},
        thread_id = event.threadId,
        item_id = pending.last_item_id,
      })
    end
    return
  end

  if event.type == "assistant.message" then
    pending.last_text = event.text or ""
    pending.last_item_id = event.itemId or pending.last_item_id
    if callbacks.on_response then
      callbacks.on_response({
        role = "assistant",
        content = pending.last_text,
        ts = util.now(),
        touched_files = {},
        thread_id = event.threadId,
        item_id = pending.last_item_id,
      })
    end
    return
  end

  if event.type == "files.touched" then
    pending.touched = pending.touched or {}
    for _, path in ipairs(event.paths or {}) do
      pending.touched[path] = true
    end
    return
  end

  if event.type == "error" then
    if callbacks.on_error then
      callbacks.on_error({ message = event.message or "Codex SDK error", thread_id = event.threadId })
    else
      notify("codex.nvim: " .. (event.message or "Codex SDK error"), vim.log.levels.ERROR)
    end
    if callbacks.on_done then
      callbacks.on_done()
    end
    finish_pending()
    return
  end

  if event.type == "done" then
    local touched_files = table_keys(pending.touched)
    local final_response = event.finalResponse or ""
    local should_emit = final_response ~= "" and final_response ~= pending.last_text

    if should_emit and callbacks.on_response then
      callbacks.on_response({
        role = "assistant",
        content = final_response,
        ts = util.now(),
        touched_files = touched_files,
        thread_id = event.threadId,
        item_id = pending.last_item_id,
      })
    elseif #touched_files > 0 and callbacks.on_response then
      callbacks.on_response({
        role = "assistant",
        content = pending.last_text or "",
        ts = util.now(),
        touched_files = touched_files,
        thread_id = event.threadId,
        item_id = pending.last_item_id,
      })
    end

    if callbacks.on_done then
      callbacks.on_done()
    end
    finish_pending()
  end
end

function M._pump()
  if running then
    return
  end
  if not ensure_job() then
    return
  end
  local next_item = table.remove(queue, 1)
  if not next_item then
    return
  end

  pending = next_item
  running = true

  local request = {
    type = "run",
    sessionId = next_item.session_id,
    threadId = next_item.thread_id,
    cwd = next_item.cwd,
    input = next_item.input,
    model = next_item.model,
    threadOptions = next_item.thread_options,
  }

  if not send_request(request) then
    notify("codex.nvim: failed to send request to SDK bridge", vim.log.levels.ERROR)
    local callbacks = next_item.callbacks or {}
    if callbacks.on_error then
      callbacks.on_error({ message = "failed to send request" })
    end
    if callbacks.on_done then
      callbacks.on_done()
    end
    finish_pending()
  end
end

function M.start_session(_session)
  ensure_job()
  return true
end

function M.stop_session(session)
  if job_valid(job_id) and session and session.id then
    send_request({ type = "reset", sessionId = session.id })
  end
  return true
end

function M.send_message(session, message, callbacks)
  callbacks = callbacks or {}

  local backend = backend_config()
  local session_id = session.id
  local thread_id = session.thread_id
  local cwd = session.root or state.root
  local thread_options = build_thread_options(session)
  local model = backend.model

  table.insert(queue, {
    session_id = session_id,
    thread_id = thread_id,
    cwd = cwd,
    input = message.content,
    model = model,
    thread_options = thread_options,
    callbacks = callbacks,
    touched = {},
  })

  M._pump()
end

return M
