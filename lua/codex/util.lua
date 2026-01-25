local uv = vim.uv or vim.loop
local bitlib = bit or bit32

local M = {}

local function path_join(...)
  if vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local sep = package.config:sub(1, 1)
  return table.concat({ ... }, sep)
end

local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

local function ensure_dir(path)
  if is_dir(path) then
    return
  end
  vim.fn.mkdir(path, "p")
end

local function normalize(path)
  return vim.fs.normalize(path)
end

function M.plugin_root()
  local source = debug.getinfo(1, "S").source
  local path = source:sub(1, 1) == "@" and source:sub(2) or source
  local codex_dir = vim.fs.dirname(path)
  local lua_dir = vim.fs.dirname(codex_dir)
  local root = vim.fs.dirname(lua_dir)
  return normalize(root)
end

function M.cwd()
  return normalize(vim.fn.getcwd())
end

function M.project_root()
  local git_dir = vim.fs.find({ ".git" }, {
    upward = true,
    path = M.cwd(),
    stop = vim.fn.expand("~"),
  })[1]

  if git_dir then
    return normalize(vim.fs.dirname(git_dir))
  end

  return M.cwd()
end

local function fnv1a_32(input)
  local hash = 2166136261
  for i = 1, #input do
    hash = bitlib.bxor(hash, string.byte(input, i))
    hash = (hash * 16777619) % 4294967296
  end
  return string.format("%08x", hash)
end

function M.root_key(root)
  return fnv1a_32(root)
end

function M.root_session_file(root, storage_dir)
  ensure_dir(storage_dir)
  local key = M.root_key(root)
  return path_join(storage_dir, key .. ".json")
end

function M.expand(path)
  return vim.fn.expand(path)
end

function M.codex_sessions_dir(codex_home, sessions_subdir)
  local home = normalize(M.expand(codex_home))
  return path_join(home, sessions_subdir or "sessions")
end

function M.read_json(path)
  local fd = uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data or data == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then
    vim.notify("codex.nvim: failed to decode JSON at " .. path, vim.log.levels.WARN)
    return nil
  end
  return decoded
end

function M.write_json(path, tbl)
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then
    vim.notify("codex.nvim: failed to encode session JSON", vim.log.levels.ERROR)
    return false
  end
  local fd = uv.fs_open(path, "w", 420)
  if not fd then
    vim.notify("codex.nvim: failed to open " .. path .. " for writing", vim.log.levels.ERROR)
    return false
  end
  uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  return true
end

function M.now()
  return os.time()
end

function M.iso8601(ts)
  local time = ts or M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ", time)
end

function M.parse_iso8601(value)
  if not value or value == "" then
    return nil
  end
  local trimmed = value:gsub("%.%d+", ""):gsub("Z$", "")
  local pattern = "%Y-%m-%dT%H:%M:%S"
  local ok, parsed = pcall(vim.fn.strptime, pattern, trimmed)
  if not ok or not parsed or parsed <= 0 then
    return nil
  end
  return parsed
end

function M.format_time(ts)
  if not ts then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M", ts)
end

function M.short_id(id)
  if not id then
    return ""
  end
  return id:sub(1, 8)
end

function M.debounce(ms, fn)
  local timer = uv.new_timer()
  local debounced = function(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
  return debounced, timer
end

function M.basename(path)
  return vim.fs.basename(path)
end

function M.relative(root, path)
  if vim.fs.relpath then
    return vim.fs.relpath(root, path)
  end
  local prefix = root
  if not prefix:match("/$") then
    prefix = prefix .. "/"
  end
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

function M.is_subpath(root, candidate)
  local root_norm = normalize(root)
  local cand_norm = normalize(candidate)
  if cand_norm == root_norm then
    return true
  end
  local prefix = root_norm
  local sep = package.config:sub(1, 1)
  if not prefix:match(sep .. "$") then
    prefix = prefix .. sep
  end
  return cand_norm:sub(1, #prefix) == prefix
end

function M.is_absolute(path)
  if vim.fs.isabsolute then
    return vim.fs.isabsolute(path)
  end
  local sep = package.config:sub(1, 1)
  if sep == "\\" then
    return path:match("^%a:[/\\]") ~= nil
  end
  return path:sub(1, 1) == "/"
end

function M.read_first_line(path)
  local fd = uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end
  local chunk = uv.fs_read(fd, 4096, 0)
  uv.fs_close(fd)
  if not chunk or chunk == "" then
    return nil
  end
  local line = chunk:match("([^\n]+)")
  return line
end

local function random_hex(count)
  local pieces = {}
  for _ = 1, count do
    pieces[#pieces + 1] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(pieces)
end

function M.uuid4()
  local part1 = random_hex(4)
  local part2 = random_hex(2)
  local part3 = string.format("4%s", random_hex(2):sub(2))
  local variant = (math.random(0, 15) % 4) + 8
  local part4 = string.format("%x%s", variant, random_hex(2):sub(2))
  local part5 = random_hex(6)
  return table.concat({ part1, part2, part3, part4, part5 }, "-")
end

function M.is_ignored(path, ignore_list)
  for _, ignore in ipairs(ignore_list or {}) do
    if path:find(ignore, 1, true) then
      return true
    end
  end
  return false
end

return M
