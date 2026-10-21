--- One Claude conversation: a `claude -p` process speaking stream-json, plus its
--- output and input buffers.

local api = vim.api
local root = (...):match '^(.*%.)'
local config = require(root .. 'config')
local render = require(root .. 'render')
local tasks = require(root .. 'tasks')

local M = {}

---@type table<integer, yacc.Session>
M.sessions = {}
---@type integer?
M.current = nil
--- Plan usage windows from the last rate_limit_event, shared by all sessions
---@type table<string, {utilization?: number, resetsAt?: integer}>?
M.rate = nil

---@class yacc.Session
---@field id integer
---@field cwd string
---@field session_id? string Claude session uuid, known after the init message or from history
---@field title? string
---@field proc? vim.SystemObj
---@field state 'stopped'|'starting'|'idle'|'busy'
---@field cmds table<string, cc.Command> Messages sent and not finished, keyed by uuid
---@field queue string[] Uuids of messages the CLI holds until a tool boundary or the turn end
---@field held string[] Uuids of messages not sent yet, waiting out send_delay_ms, newest last
---@field cancelled string[] Cancelled messages that did not go back to the input, for its history
---@field activity? string What the running turn does now, for the footer
---@field context? integer Tokens in the context after the last turn
---@field context_window? integer Context size of the model, as the CLI reports it after a turn
---@field tasks table<string, cc.Task> Shells and subagents, by tool_use_id
---@field task_order string[] tool_use_ids in start order
---@field task_ids table<string, string> tool_use_id of each CLI task id
---@field suggestion? string Next prompt the CLI suggests, until a turn starts
---@field remote? {url: string} Remote Control, while it is on
---@field remote_state? string Bridge state the CLI reports, 'connected' once claude.ai reached it
---@field remote_wanted? boolean Turn Remote Control back on when the process restarts
---@field images yacc.Image[] Pasted images, `[Image #n]` in a prompt refers to images[n]
---@field interrupting boolean
---@field history? {idx: integer, draft?: string[]} Position in the input history
---@field stopping boolean
---@field model? string
---@field permission_mode? string
---@field commands {name: string, description: string, argumentHint?: string}[]
---@field models {value: string, displayName: string, description: string}[]
---@field out integer Output buffer
---@field input integer Input buffer
---@field render yacc.Render
---@field pending table<string, fun(resp: table)> Our control requests waiting for a reply
---@field next_req integer
---@field stdout_tail string Last unterminated stdout line
---@field stderr string[]
---@field exit_cbs fun()[] Called once after the process exits
local S = {}
S.__index = S

---@class yacc.Command
---@field text string
---@field kind 'prompt'|'clear'
---@field rendered boolean The prompt is in the output buffer

---@return string
local function uuid()
  local b = { vim.uv.random(16):byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = ('%02x'):rep(16):format(unpack(b))
  return ('%s-%s-%s-%s-%s'):format(hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21))
end

---@param kind 'output'|'input'
---@param ft string
---@return integer
local function make_buf(kind, ft)
  local buf = api.nvim_create_buf(false, true)
  vim.b[buf].cc_kind = kind
  vim.bo[buf].filetype = ft
  pcall(vim.treesitter.start, buf, 'markdown')
  return buf
end

---@return yacc.RenderOpts
function M.render_opts()
  local o = config.options
  return {
    max_lines = o.max_lines,
    fold_tools = o.fold_tools,
    fold_threshold = o.fold_threshold,
    code_fold_lines = o.code_fold_lines,
  }
end

---@param want? integer
---@return integer
local function free_id(want)
  if want and want > 0 and not M.sessions[want] then
    return want
  end
  local id = 1
  while M.sessions[id] do
    id = id + 1
  end
  return id
end

---@class yacc.NewOpts
---@field id? integer Wanted session number, the first free one when taken or nil
---@field cwd? string
---@field resume? string Claude session uuid to continue
---@field title? string

---@param opts? yacc.NewOpts
---@return yacc.Session
function M.new(opts)
  opts = opts or {}
  local id = free_id(opts.id)
  local self = setmetatable({
    id = id,
    cwd = opts.cwd or vim.fn.getcwd(),
    session_id = opts.resume,
    title = opts.title,
    state = 'stopped',
    cmds = {},
    queue = {},
    held = {},
    cancelled = {},
    images = {},
    interrupting = false,
    stopping = false,
    commands = {},
    models = {},
    pending = {},
    next_req = 0,
    stdout_tail = '',
    stderr = {},
    exit_cbs = {},
    tasks = {},
    task_order = {},
    task_ids = {},
  }, S)
  self.out = make_buf('output', 'cc-output')
  vim.bo[self.out].modifiable = false
  -- `:edit` empties a named scratch buffer, then runs BufReadCmd: render the transcript
  -- again. The input has no name, so `:edit` there fails with E32 and keeps the draft.
  api.nvim_buf_set_name(self.out, ('claude://%d/output'):format(id))
  api.nvim_create_autocmd('BufReadCmd', {
    buffer = self.out,
    callback = function()
      require(root .. 'ui').rerender(self)
    end,
  })
  self.input = make_buf('input', 'cc-input')
  vim.b[self.out].cc_session = id
  vim.b[self.input].cc_session = id
  self.render = render.new(self.out, M.render_opts())
  M.sessions[id] = self
  M.current = id
  return self
end

---@param buf? integer
---@return yacc.Session?
function M.from_buf(buf)
  local id = vim.b[buf or 0].cc_session
  return id and M.sessions[id] or nil
end

---@return yacc.Session[]
function M.list()
  local list = vim.tbl_values(M.sessions)
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

---@return string[]
function S:_cmd()
  local o = config.options
  local cmd = vim.list_extend(vim.list_slice(o.cmd), {
    '-p',
    '--input-format',
    'stream-json',
    '--output-format',
    'stream-json',
    '--verbose',
    '--permission-prompt-tool',
    'stdio',
  })
  if o.partial_messages then
    cmd[#cmd + 1] = '--include-partial-messages'
  end
  if self.session_id then
    vim.list_extend(cmd, { '--resume', self.session_id })
  end
  local model = self.model or o.model
  if model then
    vim.list_extend(cmd, { '--model', model })
  end
  local mode = self.permission_mode or o.permission_mode
  if mode then
    vim.list_extend(cmd, { '--permission-mode', mode })
  end
  return cmd
end

function S:start()
  if self.proc then
    return
  end
  local o = config.options
  local env = vim.fn.environ()
  -- In -p mode the CLI uses this key without asking, and bills it instead of the subscription
  if not o.allow_api_key then
    env.ANTHROPIC_API_KEY = nil
  end
  env = vim.tbl_extend('force', env, o.env)

  self.stdout_tail = ''
  self.stderr = {}
  self.stopping = false
  local ok, proc = pcall(vim.system, self:_cmd(), {
    cwd = self.cwd,
    env = env,
    clear_env = true,
    stdin = true,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          self:_on_stdout(data)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          vim.list_extend(self.stderr, vim.split(data, '\n', { trimempty = true }))
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self:_on_exit(obj)
    end)
  end)
  if not ok then
    self.render:error(('Cannot start `%s`: %s'):format(o.cmd[1], proc))
    return
  end
  self.proc = proc
  self.state = 'starting'
  self:request({ subtype = 'initialize', promptSuggestions = o.suggestions }, function(resp)
    local r = resp.response or {}
    self.commands = r.commands or {}
    self.models = r.models or {}
    self.permission_mode = r.current_permission_mode or self.permission_mode
    if self.state == 'starting' then
      self.state = 'idle'
    end
    local rc = o.remote_control
    if self.remote_wanted or rc == true or (rc == 'auto' and r.remote_control_auto_enable) then
      self:set_remote(true)
    end
    self:changed()
  end)
  self:changed()
end

---@param data string
function S:_on_stdout(data)
  local lines = vim.split(self.stdout_tail .. data, '\n', { plain = true })
  self.stdout_tail = table.remove(lines)
  for _, line in ipairs(lines) do
    if line ~= '' then
      local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(msg) == 'table' then
        local hok, err = pcall(self._handle, self, msg)
        if not hok then
          vim.notify(('yacc: %s'):format(err), vim.log.levels.ERROR)
        end
      end
    end
  end
end

---@param obj vim.SystemCompleted
function S:_on_exit(obj)
  self.proc = nil
  self.remote = nil
  self.remote_state = nil
  self.state = 'stopped'
  self.cmds = {}
  self.queue = {}
  self.activity = nil
  self.interrupting = false
  self.render:turn_end()
  tasks.stop_all(self)
  require(root .. 'permission').drop(self)
  if obj.code ~= 0 and not self.stopping then
    local tail = vim.list_slice(self.stderr, math.max(1, #self.stderr - 10))
    self.render:error(('claude exited with code %d\n%s'):format(obj.code, table.concat(tail, '\n')))
  end
  self:changed()
  local cbs = self.exit_cbs
  self.exit_cbs = {}
  for _, cb in ipairs(cbs) do
    cb()
  end
end

---@param msg table
function S:_handle(msg)
  local t = msg.type
  -- Subagent internals: only its tool calls are listed under the Task block
  if msg.parent_tool_use_id and (t == 'stream_event' or t == 'assistant' or t == 'user') then
    if t == 'assistant' then
      self.render:subagent(msg.parent_tool_use_id, msg.message)
    end
    return
  end
  if t == 'stream_event' then
    self:_activity(msg.event)
    self.render:stream_event(msg.event)
  elseif t == 'assistant' then
    self.render:assistant(msg.message)
    for _, c in ipairs(msg.message.content or {}) do
      if c.type == 'tool_use' then
        tasks.tool_use(self, c)
      end
    end
    self:changed()
  elseif t == 'user' then
    self.activity = 'thinking'
    self.render:user_message(msg.message, true)
    local content = msg.message.content
    for _, c in ipairs(type(content) == 'table' and content or {}) do
      if c.type == 'tool_result' then
        tasks.tool_result(self, c)
      end
    end
    self:changed()
  elseif t == 'prompt_suggestion' then
    self.suggestion = msg.suggestion
    self:changed()
    require(root .. 'ui').suggest(self)
  elseif t == 'rate_limit_event' then
    local info = msg.rate_limit_info or {}
    M.rate = info.unifiedWindows or M.rate
    self:changed()
  elseif t == 'command_lifecycle' then
    self:_lifecycle(msg.command_uuid, msg.state)
  elseif t == 'system' then
    if msg.subtype == 'init' then
      self.session_id = msg.session_id
      self.model = msg.model
      self.permission_mode = msg.permissionMode
      self:changed()
    elseif msg.subtype == 'status' and msg.permissionMode then
      self.permission_mode = msg.permissionMode
      self:changed()
    elseif msg.subtype == 'bridge_state' then
      -- It comes before the response to remote_control
      self.remote_state = msg.state
      self:changed()
    elseif tasks.event(self, msg) then
      self:changed()
    elseif msg.subtype == 'compact_boundary' then
      self.render:compacted()
    elseif msg.subtype == 'informational' and type(msg.content) == 'string' then
      self.render:note(vim.split(msg.content, '\n', { plain = true }))
    end
  elseif t == 'result' then
    self.render:turn_end()
    if self.interrupting then
      self.render:note { 'Interrupted' }
    elseif msg.is_error or msg.subtype ~= 'success' then
      local errors = msg.errors and table.concat(msg.errors, '\n')
      self.render:error(msg.result or errors or msg.subtype)
    end
    self.interrupting = false
    self.activity = nil
    -- Results inserted above a mark moved it, keep its anchor right
    require(root .. 'marks').save(self)
    -- The last API call of the turn holds the whole context
    local u = msg.usage
    local last = u and (u.iterations and u.iterations[#u.iterations] or u)
    if last then
      self.context = (last.input_tokens or 0)
        + (last.cache_read_input_tokens or 0)
        + (last.cache_creation_input_tokens or 0)
        + (last.output_tokens or 0)
    end
    -- Subagents add their own models, the session's is the one it was started with
    local usage = msg.modelUsage or {}
    local main = usage[self.model or ''] or usage[(self.model or ''):gsub('%[1m%]$', '')]
    if main and main.contextWindow then
      self.context_window = main.contextWindow
    elseif next(usage) then
      -- `self.model` can be an alias such as 'haiku', take the largest window
      local window = 0
      for _, m in pairs(usage) do
        window = math.max(window, m.contextWindow or 0)
      end
      self.context_window = window > 0 and window or nil
    end
    -- Messages still queued start the next turn
    self.state = #self.queue > 0 and 'busy' or 'idle'
    self:changed()
  elseif t == 'control_request' then
    local req = msg.request
    if req.subtype == 'can_use_tool' then
      require(root .. 'permission').ask(self, msg.request_id, req)
    else
      self:respond_error(msg.request_id, 'unsupported request: ' .. tostring(req.subtype))
    end
  elseif t == 'control_response' then
    local resp = msg.response
    local cb = self.pending[resp.request_id]
    self.pending[resp.request_id] = nil
    if resp.subtype == 'error' then
      vim.notify(('yacc: %s'):format(resp.error), vim.log.levels.WARN)
    elseif cb then
      cb(resp)
    end
  elseif t == 'control_cancel_request' then
    require(root .. 'permission').cancel(self, msg.request_id)
  end
end

---@param ev table
function S:_activity(ev)
  if self.interrupting then
    return
  end
  if ev.type == 'message_start' then
    self.activity = 'thinking'
  elseif ev.type == 'content_block_start' then
    local cb = ev.content_block
    if cb.type == 'text' then
      self.activity = 'writing'
    elseif cb.type == 'thinking' then
      self.activity = 'thinking'
    elseif cb.type == 'tool_use' or cb.type == 'server_tool_use' then
      self.activity = 'running ' .. cb.name
    end
  end
end

---@param id string
---@param state string
function S:_lifecycle(id, state)
  local c = self.cmds[id]
  if not c then
    -- A prompt sent through Remote Control
    if state == 'started' then
      self.state = 'busy'
      self.suggestion = nil
      local path = self.session_id
        and vim.fs.joinpath(require(root .. 'history').project_dir(self.cwd), self.session_id .. '.jsonl')
      local text = path and require(root .. 'history').user_text(path, id)
      self.render:user(text or '(a prompt sent through Remote Control)')
      self:changed()
    end
    return
  end
  if state == 'started' then
    self:_unqueue(id)
    self.state = 'busy'
    self.suggestion = nil
    if c.kind == 'prompt' and not c.rendered then
      c.rendered = true
      self.render:user(c.text)
    elseif c.kind == 'clear' then
      -- Its completed frame comes after the result, too late if a prompt follows fast
      self:reset_output()
      self.title = nil
      self.render:note { 'Context cleared' }
    end
  elseif state ~= 'queued' then
    self.cmds[id] = nil
    self:_unqueue(id)
    if state == 'refused' then
      self.render:error('The CLI refused the message: ' .. vim.split(c.text, '\n', { plain = true })[1])
    end
  end
  self:changed()
end

---@param id string
function S:_unqueue(id)
  for i, q in ipairs(self.queue) do
    if q == id then
      table.remove(self.queue, i)
      return
    end
  end
end

---@param obj table
function S:send(obj)
  if not self.proc then
    return
  end
  self.proc:write(vim.json.encode(obj) .. '\n')
end

---@param req table
---@param cb? fun(resp: table)
function S:request(req, cb)
  self.next_req = self.next_req + 1
  local id = ('cc-%d'):format(self.next_req)
  self.pending[id] = cb
  self:send { type = 'control_request', request_id = id, request = req }
end

---@param request_id string
---@param response table
function S:respond(request_id, response)
  self:send {
    type = 'control_response',
    response = { subtype = 'success', request_id = request_id, response = response },
  }
end

---@param request_id string
---@param err string
function S:respond_error(request_id, err)
  self:send {
    type = 'control_response',
    response = { subtype = 'error', request_id = request_id, error = err },
  }
end

--- Text and image blocks for a prompt, with the images its placeholders name
---@param text string
---@return string|table
function S:_content(text)
  local blocks, seen = {}, {}
  for n in text:gmatch '%[Image #(%d+)%]' do
    local img = self.images[tonumber(n)]
    if img and not seen[n] then
      seen[n] = true
      blocks[#blocks + 1] =
        { type = 'image', source = { type = 'base64', media_type = img.media_type, data = img.data } }
    end
  end
  if #blocks == 0 then
    return text
  end
  table.insert(blocks, 1, { type = 'text', text = text })
  return blocks
end

--- Send a message after send_delay_ms, so a send by mistake can be cancelled. While a
--- turn runs, the CLI queues it and delivers it at the next tool boundary, or after the
--- turn. Its prompt is rendered when it starts.
---@param text string
---@param kind? 'prompt'|'clear'
function S:submit(text, kind)
  text = vim.trim(text)
  if text == '' then
    return
  end
  -- Started now, the process is ready when the delay ends
  self:start()
  if not self.proc then
    return
  end
  local id = uuid()
  self.cmds[id] = { text = text, kind = kind or 'prompt', rendered = false }
  local delay = config.options.send_delay_ms
  if delay > 0 then
    self.held[#self.held + 1] = id
    self.cmds[id].timer = vim.defer_fn(function()
      self:_deliver(id)
    end, delay)
    self:changed()
  else
    self:_deliver(id)
  end
end

--- Cancel the newest message still waiting out its send delay
---@return string? text Nil when none waits
function S:cancel_held()
  local id = table.remove(self.held)
  local c = id and self.cmds[id]
  if not c then
    return nil
  end
  self.cmds[id] = nil
  if c.timer and not c.timer:is_closing() then
    c.timer:stop()
    c.timer:close()
  end
  self:changed()
  return c.text
end

---@param id string
function S:_deliver(id)
  local c = self.cmds[id]
  if not c then
    return
  end
  c.timer = nil
  for i, h in ipairs(self.held) do
    if h == id then
      table.remove(self.held, i)
      break
    end
  end
  self:start()
  if not self.proc then
    self.cmds[id] = nil
    self:changed()
    return
  end
  local text, kind = c.text, c.kind
  if kind == 'prompt' then
    self.title = self.title or vim.split(text, '\n', { plain = true })[1]:sub(1, 60)
  end
  if self.state == 'busy' then
    self.queue[#self.queue + 1] = id
  elseif kind == 'prompt' then
    c.rendered = true
    self.render:user(text)
  end
  self.state = 'busy'
  self.activity = self.activity or 'thinking'
  self:send { type = 'user', uuid = id, message = { role = 'user', content = self:_content(text) } }
  self:changed()
end

--- Turn Remote Control on or off. On, the session can be continued from claude.ai or the
--- mobile app, and its URL goes to the + register.
---@param enabled boolean
function S:set_remote(enabled)
  self.remote_wanted = enabled
  -- The initialize response turns it on, with remote_wanted
  if not self.proc then
    if enabled then
      self:start()
    end
    return
  end
  self:request({ subtype = 'remote_control', enabled = enabled, name = self.title }, function(resp)
    if not enabled then
      self.remote = nil
      self.render:note { 'Remote Control off' }
      return self:changed()
    end
    local url = (resp.response or {}).session_url
    if not url then
      return
    end
    self.remote = { url = url }
    pcall(vim.fn.setreg, '+', url)
    self.render:note { 'Remote Control: ' .. url }
    vim.notify(('Claude: Remote Control on, %s (copied)'):format(url))
    self:changed()
  end)
end

--- Start a new conversation. The CLI gives it a new session id.
function S:clear()
  if self.state == 'busy' then
    vim.notify('Claude: the session is busy, interrupt it before /clear', vim.log.levels.WARN)
    return
  end
  self:submit('/clear', 'clear')
end

function S:interrupt()
  if self.state ~= 'busy' or self.interrupting then
    return
  end
  self.interrupting = true
  self.activity = 'interrupting'
  self:request { subtype = 'interrupt' }
  self:changed()
end

---@param mode string
function S:set_mode(mode)
  if not self.proc then
    self.permission_mode = mode
    return self:changed()
  end
  self:request({ subtype = 'set_permission_mode', mode = mode }, function()
    self.permission_mode = mode
    self.render:note { ('Mode: %s'):format(mode) }
    self:changed()
  end)
end

---@param model string
function S:set_model(model)
  if not self.proc then
    self.model = model
    return self:changed()
  end
  self:request({ subtype = 'set_model', model = model }, function()
    self.model = model
    self.render:note { ('Model: %s'):format(model) }
    self:changed()
  end)
end

function S:stop()
  if self.proc then
    self.stopping = true
    self.proc:kill 'sigterm'
  end
end

--- Stop the process, then call `fn` once it has exited
---@param fn fun()
function S:stop_then(fn)
  if not self.proc then
    return fn()
  end
  self.exit_cbs[#self.exit_cbs + 1] = fn
  self:stop()
end

function S:close()
  require(root .. 'marks').save(self)
  -- selene: allow(empty_loop)
  while self:cancel_held() do
  end
  self:stop()
  require(root .. 'permission').drop(self)
  M.sessions[self.id] = nil
  for _, buf in ipairs { self.out, self.input } do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  if M.current == self.id then
    local next = M.list()[1]
    M.current = next and next.id or nil
  end
end

--- Throw away the rendered conversation and start an empty one in the same buffer
function S:reset_output()
  vim.bo[self.out].modifiable = true
  api.nvim_buf_set_lines(self.out, 0, -1, false, {})
  vim.bo[self.out].modifiable = false
  api.nvim_buf_clear_namespace(self.out, render.ns, 0, -1)
  api.nvim_buf_clear_namespace(self.out, render.ns_deco, 0, -1)
  api.nvim_buf_clear_namespace(self.out, render.ns_open, 0, -1)
  api.nvim_buf_clear_namespace(self.out, render.ns_block, 0, -1)
  api.nvim_buf_clear_namespace(self.out, render.ns_status, 0, -1)
  api.nvim_buf_clear_namespace(self.out, render.ns_tail, 0, -1)
  self.render = render.new(self.out, M.render_opts())
  -- Mark indicators on deleted lines collapse onto row 0
  require(root .. 'marks').refresh(self)
end

function S:changed()
  require(root .. 'ui').refresh(self)
end

return M
