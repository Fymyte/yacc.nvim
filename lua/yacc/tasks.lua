--- Shells and subagents of a session, from their tool calls and the CLI's task events.
---
--- A foreground shell only gets its task events when it ends, so a tool call without a
--- result counts as running. A background task keeps running after its tool result,
--- until its task_notification.

local M = {}

---@class yacc.Task
---@field id string tool_use_id
---@field task_id? string Id of the CLI task, for stop_task
---@field kind 'shell'|'agent'|'task'
---@field description string
---@field started number Milliseconds, vim.uv.now()
---@field ended? number
---@field status 'running'|'completed'|'failed'|'stopped'
---@field background boolean
---@field tokens? integer Subagent tokens so far
---@field tool_uses? integer
---@field last_tool? string
---@field output_file? string
---@field drawn? string Status the title shows, to redraw a task that ended once

local kinds = { Bash = 'shell', Agent = 'agent', Task = 'agent' }
local task_kinds = { local_bash = 'shell', local_agent = 'agent' }

---@param s yacc.Session
---@param id string
---@param kind 'shell'|'agent'|'task'
---@param description string
---@return yacc.Task
local function add(s, id, kind, description)
  local t = s.tasks[id]
  if not t then
    t = {
      id = id,
      kind = kind,
      description = description,
      started = vim.uv.now(),
      status = 'running',
      background = false,
    }
    s.tasks[id] = t
    s.task_order[#s.task_order + 1] = id
  end
  return t
end

---@param t yacc.Task
---@param status 'completed'|'failed'|'stopped'
local function finish(t, status)
  if t.status == 'running' then
    t.status = status
    t.ended = vim.uv.now()
  end
end

---@param ms number
---@return string
function M.elapsed(ms)
  local secs = math.floor(ms / 1000)
  if secs < 60 then
    return ('%ds'):format(secs)
  elseif secs < 3600 then
    return ('%dm%02ds'):format(secs / 60, secs % 60)
  end
  return ('%dh%02dm'):format(secs / 3600, secs % 3600 / 60)
end

---@param n number
---@return string
local function kilo(n)
  return n >= 1000 and ('%dk'):format(n / 1000) or tostring(n)
end

--- Status after the tool's title. Nil for a foreground tool that ended, its result
--- already shows how it went.
---@param t yacc.Task
---@param frame string Spinner character
---@return [string, string][]?
function M.chunks(t, frame)
  if t.status == 'running' then
    local parts = { ('%s %s'):format(frame, M.elapsed(vim.uv.now() - t.started)) }
    if t.last_tool then
      parts[#parts + 1] = t.last_tool
    end
    if t.tokens then
      parts[#parts + 1] = kilo(t.tokens) .. ' tok'
    end
    if t.background then
      parts[#parts + 1] = 'background'
    end
    return { { table.concat(parts, ' · '), 'CcHint' } }
  elseif not t.background then
    return nil
  end
  local took = M.elapsed((t.ended or t.started) - t.started)
  if t.status == 'completed' then
    return { { '✓ ' .. took, 'DiagnosticOk' } }
  elseif t.status == 'failed' then
    return { { '✗ ' .. took, 'DiagnosticError' } }
  end
  return { { '■ stopped ' .. took, 'DiagnosticWarn' } }
end

---@param s yacc.Session
---@param frame string
function M.draw(s, frame)
  for _, t in pairs(s.tasks) do
    if t.status == 'running' or t.drawn ~= t.status then
      s.render:set_status(t.id, M.chunks(t, frame))
      t.drawn = t.status
    end
  end
end

---@param s yacc.Session
---@return yacc.Task[]
function M.running(s)
  local out = {}
  for _, id in ipairs(s.task_order) do
    if s.tasks[id].status == 'running' then
      out[#out + 1] = s.tasks[id]
    end
  end
  return out
end

--- '2 shells · 1 agent', or nil when nothing runs
---@param s yacc.Session
---@return string?
function M.summary(s)
  local n = { shell = 0, agent = 0, task = 0 }
  for _, t in ipairs(M.running(s)) do
    n[t.kind] = n[t.kind] + 1
  end
  local parts = {}
  for _, k in ipairs { 'shell', 'agent', 'task' } do
    if n[k] > 0 then
      parts[#parts + 1] = ('%d %s%s'):format(n[k], k, n[k] > 1 and 's' or '')
    end
  end
  return #parts > 0 and table.concat(parts, ' · ') or nil
end

--- A tool call from the main conversation
---@param s yacc.Session
---@param c table tool_use content block
function M.tool_use(s, c)
  local kind = kinds[c.name]
  if not kind then
    return
  end
  local input = c.input or {}
  local t = add(s, c.id, kind, input.description or input.command or input.prompt or c.name)
  t.background = t.background or input.run_in_background == true
end

---@param s yacc.Session
---@param res table tool_result content block
function M.tool_result(s, res)
  local t = s.tasks[res.tool_use_id]
  if not t then
    return
  end
  local text = type(res.content) == 'string' and res.content or ''
  if type(res.content) == 'table' then
    for _, c in ipairs(res.content) do
      text = text .. (c.text or '')
    end
  end
  t.output_file = t.output_file or text:match '(/%S+%.output)'
  if res.is_error then
    finish(t, 'failed')
  elseif not t.background then
    finish(t, 'completed')
  end
end

--- system messages task_started, task_progress, task_updated and task_notification
---@param s yacc.Session
---@param msg table
---@return boolean handled
function M.event(s, msg)
  local sub = msg.subtype
  if not (sub or ''):match '^task_' then
    return false
  end
  local id = msg.tool_use_id or s.task_ids[msg.task_id]
  if sub == 'task_started' then
    id = id or msg.task_id
    local t = add(s, id, task_kinds[msg.task_type] or 'task', msg.description or msg.task_type or 'task')
    t.task_id = msg.task_id
    t.background = t.background or msg.is_backgrounded == true
    s.task_ids[msg.task_id] = id
    return true
  end
  local t = id and s.tasks[id]
  if not t then
    return true
  end
  if sub == 'task_progress' then
    local u = msg.usage or {}
    t.tokens = u.total_tokens or t.tokens
    t.tool_uses = u.tool_uses or t.tool_uses
    t.last_tool = msg.last_tool_name or t.last_tool
  elseif sub == 'task_updated' then
    local patch = msg.patch or {}
    if patch.is_backgrounded ~= nil then
      t.background = patch.is_backgrounded
    end
  elseif sub == 'task_notification' then
    if msg.output_file and msg.output_file ~= '' then
      t.output_file = msg.output_file
    end
    finish(t, msg.status == 'failed' and 'failed' or msg.status == 'stopped' and 'stopped' or 'completed')
  end
  return true
end

--- The process exited, nothing of it runs any more
---@param s yacc.Session
function M.stop_all(s)
  for _, t in pairs(s.tasks) do
    finish(t, 'stopped')
  end
end

return M
