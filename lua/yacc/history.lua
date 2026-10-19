--- Past sessions, read from the jsonl transcripts the CLI keeps per project

local M = {}

---@class cc.HistoryItem
---@field id string Claude session uuid
---@field path string
---@field mtime integer
---@field title string
---@field cwd string Directory the session was started in, the CLI resumes it from there
---@field size integer

local function config_dir()
  return vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME, '.claude')
end

--- The CLI names the project directory after the cwd, with every other character
--- than [A-Za-z0-9] replaced by '-'
---@param cwd string
---@return string
function M.project_dir(cwd)
  return vim.fs.joinpath(config_dir(), 'projects', (cwd:gsub('[^%w]', '-')))
end

---@param path string
---@param offset integer
---@param size integer
---@return string
local function read_at(path, offset, size)
  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then
    return ''
  end
  local data = vim.uv.fs_read(fd, size, offset) or ''
  vim.uv.fs_close(fd)
  return data
end

--- The CLI repeats title records through the file, so the last chunk is enough to
--- name a session without reading a transcript that can reach tens of MiB
local CHUNK = 256 * 1024

---@param path string
---@param size integer
---@return string?
local function find_title(path, size)
  local function scan(data)
    local custom, ai, prompt
    for line in data:gmatch '[^\n]+' do
      if line:find('"type":"custom-title"', 1, true) then
        local ok, o = pcall(vim.json.decode, line)
        custom = ok and o.customTitle or custom
      elseif line:find('"type":"ai-title"', 1, true) then
        local ok, o = pcall(vim.json.decode, line)
        ai = ok and o.aiTitle or ai
      elseif line:find('"type":"last-prompt"', 1, true) then
        local ok, o = pcall(vim.json.decode, line)
        prompt = ok and o.lastPrompt or prompt
      end
    end
    return custom or ai or prompt
  end
  return scan(read_at(path, math.max(0, size - CHUNK), CHUNK))
    or (size > CHUNK and scan(read_at(path, 0, CHUNK)))
    or nil
end

--- Model of the last assistant message. `--resume` alone falls back to the default
--- model when the CLI does not recognize the session's model ID.
---@param path string
---@return string?
function M.last_model(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local function scan(data)
    local model
    for line in data:gmatch '[^\n]+' do
      if line:find('"type":"assistant"', 1, true) then
        local m = line:match '"model":"([^"]+)"'
        if m and m ~= '<synthetic>' then
          model = m
        end
      end
    end
    return model
  end
  local model = scan(read_at(path, math.max(0, stat.size - CHUNK), CHUNK))
    or (stat.size > CHUNK and scan(read_at(path, 0, stat.size)))
    or nil
  -- Messages carry the API model ID, the session's '[1m]' variant is only in the
  -- model attachments
  if model and not model:find('[1m]', 1, true) then
    local all = read_at(path, 0, stat.size)
    if all and all:find(('"modelId":"%s[1m]"'):format(model), 1, true) then
      model = model .. '[1m]'
    end
  end
  return model
end

--- Text of the user message `uuid`, near the end of a transcript. Prompts sent through
--- Remote Control reach stdout only as lifecycle frames, the transcript has their text.
---@param path string
---@param uuid string
---@return string?
function M.user_text(path, uuid)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local needle = ('"uuid":"%s"'):format(uuid)
  for line in read_at(path, math.max(0, stat.size - CHUNK), CHUNK):gmatch '[^\n]+' do
    if line:find(needle, 1, true) and line:find('"type":"user"', 1, true) then
      local ok, d = pcall(vim.json.decode, line)
      local content = ok and type(d) == 'table' and d.message and d.message.content
      if type(content) == 'string' then
        return content
      elseif type(content) == 'table' then
        local parts = {}
        for _, c in ipairs(content) do
          if c.type == 'text' then
            parts[#parts + 1] = c.text
          end
        end
        return #parts > 0 and table.concat(parts, '\n') or nil
      end
    end
  end
end

--- Worktrees of the git repository holding `cwd`, or just `cwd` outside a repository
---@param cwd string
---@return string[]
function M.worktrees(cwd)
  local res = vim.system({ 'git', '-C', cwd, 'worktree', 'list', '--porcelain' }, { text = true }):wait()
  local paths = { cwd }
  if res.code == 0 then
    for path in res.stdout:gmatch 'worktree ([^\n]+)' do
      if path ~= cwd then
        paths[#paths + 1] = path
      end
    end
  end
  return paths
end

--- Project directories to list, like Claude Code's /resume: every worktree of the
--- current repository, or every project with `all`
---@param cwd string
---@param all boolean
---@return string[]
local function project_dirs(cwd, all)
  if not all then
    return vim.tbl_map(M.project_dir, M.worktrees(cwd))
  end
  local root = vim.fs.joinpath(config_dir(), 'projects')
  local dirs = {}
  for name, type in vim.fs.dir(root) do
    if type == 'directory' then
      dirs[#dirs + 1] = vim.fs.joinpath(root, name)
    end
  end
  return dirs
end

---@param path string
---@return string?
local function find_cwd(path)
  return read_at(path, 0, CHUNK):match '"cwd":"([^"]+)"'
end

---@param cwd string
---@param limit integer
---@param all? boolean Every project, not only the worktrees of the current repository
---@return cc.HistoryItem[]
function M.list(cwd, limit, all)
  local items = {}
  for _, dir in ipairs(project_dirs(cwd, all or false)) do
    for name, type in vim.fs.dir(dir) do
      if type == 'file' and name:match '%.jsonl$' then
        local path = vim.fs.joinpath(dir, name)
        local stat = vim.uv.fs_stat(path)
        if stat then
          items[#items + 1] = { id = name:sub(1, -7), path = path, mtime = stat.mtime.sec, size = stat.size }
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.mtime > b.mtime
  end)
  items = vim.list_slice(items, 1, limit)
  for _, item in ipairs(items) do
    local title = find_title(item.path, item.size) or ('untitled ' .. item.id:sub(1, 8))
    item.title = vim.split(title, '\n', { plain = true })[1]
    item.cwd = find_cwd(item.path) or cwd
  end
  return items
end

--- CLI-generated user text that is not a prompt
local function is_cli_text(text)
  return text:match '^%s*<local%-command'
    or text:match '^%s*<command%-'
    or text:match '^%s*<bash%-'
    or text:match '^%s*<system%-reminder>'
end

---@param msg table
---@return boolean
local function skip_user(msg)
  local c = msg.content
  if type(c) == 'string' then
    return is_cli_text(c) ~= nil
  end
  for _, b in ipairs(c or {}) do
    if b.type == 'text' and is_cli_text(b.text) then
      return true
    end
  end
  return false
end

--- `2026-10-14T09:00:43.153Z` to epoch seconds
---@param s string
---@return number?
local function iso_time(s)
  local y, mo, d, h, mi, sec = s:match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):([%d.]+)'
  if not y then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- os.time() reads its fields as local time, with the DST of today and not of that date.
  -- Count the days from the UTC fields instead (days_from_civil)
  if mo <= 2 then
    y = y - 1
  end
  local doy = math.floor((153 * ((mo + 9) % 12) + 2) / 5) + d - 1
  local days = y * 365 + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + doy - 719468
  return days * 86400 + h * 3600 + mi * 60 + tonumber(sec)
end

---@param path string
---@param r cc.Render
local function load(path, r)
  local seen = {}
  for line in io.lines(path) do
    if line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      local ok, o = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if
        ok
        and type(o) == 'table'
        and o.message
        and not o.isSidechain
        and not o.isMeta
        and not o.isCompactSummary
        and not (o.uuid and seen[o.uuid])
      then
        if o.uuid then
          seen[o.uuid] = true
        end
        local ts = o.timestamp and iso_time(o.timestamp)
        if o.type == 'assistant' then
          r:assistant(o.message, ts)
        elseif o.type == 'user' and not skip_user(o.message) then
          r:user_message(o.message, false, ts)
        end
      end
    end
  end
  r:turn_end()
end

---@class cc.Message
---@field kind 'user'|'assistant'
---@field text string
---@field prompt integer Number of the prompt this message belongs to, 0 before the first
---@field ts? number

---@type table<string, {mtime: integer, size: integer, messages: cc.Message[]}>
local index_cache = {}

--- Prompts and text answers of a transcript, for search. Follows the same filters as
--- load(), so prompt numbers match the rendered output.
---@param path string
---@return cc.Message[]
function M.messages(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  local c = index_cache[path]
  if c and c.mtime == stat.mtime.sec and c.size == stat.size then
    return c.messages
  end
  local out, prompt, seen = {}, 0, {}
  for line in io.lines(path) do
    if line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      local ok, o = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if
        ok
        and type(o) == 'table'
        and o.message
        and not o.isSidechain
        and not o.isMeta
        and not o.isCompactSummary
        and not (o.uuid and seen[o.uuid])
      then
        if o.uuid then
          seen[o.uuid] = true
        end
        local ts = o.timestamp and iso_time(o.timestamp)
        local content = o.message.content
        if type(content) == 'string' then
          content = { { type = 'text', text = content } }
        end
        if o.type == 'assistant' then
          for _, b in ipairs(content or {}) do
            if b.type == 'text' and b.text ~= '' then
              out[#out + 1] = { kind = 'assistant', text = b.text, prompt = prompt, ts = ts }
            end
          end
        elseif not skip_user(o.message) then
          local texts = {}
          for _, b in ipairs(content or {}) do
            if b.type == 'text' then
              texts[#texts + 1] = b.text
            end
          end
          local text = table.concat(texts, '\n')
          if text ~= '' and not text:match '^%[Request interrupted' then
            prompt = prompt + 1
            out[#out + 1] = { kind = 'user', text = vim.trim(text), prompt = prompt, ts = ts }
          end
        end
      end
    end
  end
  index_cache[path] = { mtime = stat.mtime.sec, size = stat.size, messages = out }
  return out
end

--- Render a transcript into the output buffer
---@param path string
---@param r cc.Render
function M.load(path, r)
  r:batch(function()
    load(path, r)
  end)
end

return M
