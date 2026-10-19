--- The panel: output window on top, input window below, on the right of each tabpage

local api = vim.api
local root = (...):match '^(.*%.)'
local config = require(root .. 'config')
local session = require(root .. 'session')
local tasks = require(root .. 'tasks')
local render = require(root .. 'render')

local M = {}

---@class yacc.Panel
---@field out integer
---@field input integer
---@field footer? integer Float over the last row of the output
---@field footer_buf? integer

---@type table<integer, yacc.Panel> Keyed by tabpage
local panels = {}

---@param win? integer
---@return boolean
local function valid(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@return yacc.Panel?
local function panel()
  local p = panels[api.nvim_get_current_tabpage()]
  if p and valid(p.out) and valid(p.input) then
    return p
  end
end

--- Session for commands run from anywhere: the one in the current buffer, else the
--- last one shown
---@return yacc.Session?
function M.current()
  return session.from_buf(0) or (session.current and session.sessions[session.current])
end

---@param win integer
---@param opts table<string, any>
local function set_wo(win, opts)
  for k, v in pairs(opts) do
    api.nvim_set_option_value(k, v, { win = win, scope = 'local' })
  end
end

local common_wo = {
  wrap = true,
  linebreak = true,
  number = false,
  relativenumber = false,
  -- 2 cells of left padding, the output draws its bars in them
  signcolumn = 'yes',
  statuscolumn = '',
  colorcolumn = '',
  cursorline = false,
  spell = false,
  list = false,
}

--- The global 'fillchars' with some items replaced
---@param over table<string, string>
---@return string
local function fillchars(over)
  local items = {}
  for item in vim.o.fillchars:gmatch '[^,]+' do
    local k, v = item:match '^([^:]+):(.*)$'
    if k and not over[k] then
      items[#items + 1] = k .. ':' .. v
    end
  end
  for k, v in pairs(over) do
    items[#items + 1] = k .. ':' .. v
  end
  return table.concat(items, ',')
end

local function out_wo()
  return vim.tbl_extend('force', common_wo, {
    foldmethod = 'expr',
    foldexpr = render.foldexpr_expr,
    foldtext = render.foldtext_expr,
    -- Level 1 folds (short code blocks) start open, level 2 (tools, long code) closed
    foldlevel = 1,
    foldenable = true,
    -- The user bar goes in this column, the tool bar in the second sign cell
    foldcolumn = '1',
    -- The fold text pads itself, tool titles must not get a dash tail
    fillchars = fillchars { fold = ' ', foldclose = '+', foldopen = '-', foldsep = '│' },
    -- A tool without output is a one-line fold, its title is the fold text
    foldminlines = 0,
    smoothscroll = true,
    winfixwidth = true,
    -- render-markdown needs these to keep wrapped quote and list lines indented
    breakindent = true,
    breakindentopt = '',
    showbreak = '  ',
  })
end

--- Options for a picker preview showing an output buffer
---@return table<string, any>
function M.preview_wo()
  local wo = out_wo()
  wo.winfixwidth = nil
  return wo
end

local function in_wo()
  return vim.tbl_extend('force', common_wo, { foldenable = false, winfixheight = true, winfixwidth = true })
end

local spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local frame = 1
---@type uv.uv_timer_t?
local timer

---@param s string
---@return string
local function escape(s)
  return (s:gsub('%%', '%%%%'))
end

---@param keys string[]|string|false
---@return string?
local function first(keys)
  if type(keys) == 'table' then
    return keys[1]
  end
  return keys or nil
end

---@param n number
---@return string
local function kilo(n)
  return n >= 1000 and ('%.1fk'):format(n / 1000) or tostring(n)
end

--- Session title on the left. On the right: Remote Control, model, context use, and the plan usage of
--- the current 5-hour window, which the CLI reports after each turn.
---@param s yacc.Session
---@return string
local function out_winbar(s)
  local right = {}
  if s.remote then
    -- Dim until claude.ai is connected to it
    local hl = s.remote_state == 'connected' and 'CcRemote' or 'CcHint'
    right[#right + 1] = ('%%#%s#RC%%#CcHint#'):format(hl)
  end
  if s.model then
    right[#right + 1] = escape((s.model:gsub('^claude%-', '')))
  end
  if s.context then
    local window = s.context_window or (s.model or ''):match '%[1m%]' and 1000000 or 200000
    right[#right + 1] = ('ctx %s %d%%%%'):format(kilo(s.context), math.floor(s.context * 100 / window))
  end
  local five = session.rate and session.rate.five_hour
  if five and five.utilization then
    local usage = ('5h %d%%%%'):format(math.floor(five.utilization * 100 + 0.5))
    if five.resetsAt then
      usage = usage .. os.date(' ↻%H:%M', five.resetsAt)
    end
    right[#right + 1] = usage
  end
  return ('%%#CcHint# #%d %%<%s%%=%s %%*'):format(s.id, escape(s.title or 'New session'), table.concat(right, ' · '))
end

local mode_hl = {
  default = 'CcModeDefault',
  manual = 'CcModeDefault',
  plan = 'CcModePlan',
  bypassPermissions = 'CcModeBypass',
}

---@param s yacc.Session
---@return [string, string][] left
---@return [string, string][] right
local function footer_chunks(s)
  local waiting = require(root .. 'permission').count(s)
  local queued = (#s.queue > 0 and (' · %d queued'):format(#s.queue) or '')
    .. (#s.held > 0 and (' · %d sending'):format(#s.held) or '')
  local running = tasks.summary(s)
  queued = (running and ' · ' .. running or '') .. queued
  local cancel = first(config.options.keys.interrupt)
  if waiting > 0 then
    return { { 'Waiting for permission... ', 'CcHint' }, { ':CCPermission', 'CcInputLegend' } }, {}
  elseif s.state == 'busy' then
    local what = (s.activity or 'thinking'):gsub('^%l', string.upper)
    local key = first(config.options.keys.interrupt)
    return { { ('%s... %s%s'):format(what, spinner[frame], queued), 'CcHint' } },
      key and { { key, 'CcInputLegend' }, { ' to cancel ', 'CcHint' } } or {}
  elseif #s.held > 0 then
    return { { ('Sending... %s'):format(spinner[frame]), 'CcHint' } },
      cancel and { { cancel, 'CcInputLegend' }, { ' to cancel ', 'CcHint' } } or {}
  elseif s.state == 'starting' then
    return { { 'Starting...', 'CcHint' } }, {}
  elseif s.state == 'stopped' then
    return {}, { { 'stopped ', 'CcHint' } }
  end
  local left = running and { { ('%s %s'):format(spinner[frame], running), 'CcHint' } } or {}
  local right = {}
  local mode = s.permission_mode or 'default'
  right[#right + 1] = { (' %s '):format(mode:upper()), mode_hl[mode] or 'CcModeCustom' }
  right[#right + 1] = { ' ' }
  return left, right
end

local ns_footer = api.nvim_create_namespace 'cc.footer'

--- One-row float over the bottom of the output window: spinner, model and mode
---@param p yacc.Panel
---@param s yacc.Session
local function footer(p, s)
  -- Float rows count from below the winbar, so use the text area height
  local info = vim.fn.getwininfo(p.out)[1]
  local width, height = info.width, info.height
  local cfg = {
    relative = 'win',
    win = p.out,
    anchor = 'SW',
    row = height,
    col = 0,
    width = width,
    height = 1,
    style = 'minimal',
    focusable = false,
    zindex = 50,
  }
  if not (p.footer_buf and api.nvim_buf_is_valid(p.footer_buf)) then
    p.footer_buf = api.nvim_create_buf(false, true)
  end
  if valid(p.footer) then
    api.nvim_win_set_config(p.footer, cfg)
  else
    cfg.noautocmd = true
    p.footer = api.nvim_open_win(p.footer_buf, false, cfg)
    vim.wo[p.footer].winhighlight = 'NormalFloat:Normal'
  end
  local left, right = footer_chunks(s)
  api.nvim_buf_clear_namespace(p.footer_buf, ns_footer, 0, -1)
  -- Where the view is, when the end of the output is out of sight. It goes in the
  -- room between the two sides, centered when it fits there.
  local last, bottom = api.nvim_buf_line_count(s.out), vim.fn.line('w$', p.out)
  if bottom < last then
    local function chunks_width(chunks)
      local w = 0
      for _, c in ipairs(chunks) do
        w = w + vim.fn.strdisplaywidth(c[1])
      end
      return w
    end
    local from, to = chunks_width(left) + 2, width - chunks_width(right) - 2
    local text
    for _, t in ipairs {
      (' ↓ %d lines below · %d%% '):format(last - bottom, math.floor(bottom * 100 / last)),
      (' ↓ %d '):format(last - bottom),
    } do
      if vim.fn.strdisplaywidth(t) <= to - from then
        text = t
        break
      end
    end
    if text then
      local w = vim.fn.strdisplaywidth(text)
      api.nvim_buf_set_extmark(p.footer_buf, ns_footer, 0, 0, {
        virt_text = { { text, 'CcInputLegend' } },
        virt_text_pos = 'overlay',
        virt_text_win_col = math.min(math.max(from, math.floor((width - w) / 2)), to - w),
      })
    end
  end
  if #left > 0 then
    api.nvim_buf_set_extmark(p.footer_buf, ns_footer, 0, 0, { virt_text = left, virt_text_pos = 'overlay' })
  end
  if #right > 0 then
    api.nvim_buf_set_extmark(p.footer_buf, ns_footer, 0, 0, { virt_text = right, virt_text_pos = 'right_align' })
  end
end

local ns_input = api.nvim_create_namespace 'cc.input'

--- Hint over the empty input, with the keys that do something there
---@param s yacc.Session
local function placeholder(s)
  api.nvim_buf_clear_namespace(s.input, ns_input, 0, -1)
  local lines = api.nvim_buf_get_lines(s.input, 0, -1, false)
  if #lines > 1 or lines[1] ~= '' then
    return
  end
  local k = config.options.keys
  if s.suggestion then
    -- blink's ghost text in insert mode draws the same text at the same place
    local chunks = { { s.suggestion .. '  ', 'CcHint' } }
    if k.accept_suggestion then
      vim.list_extend(chunks, { { k.accept_suggestion, 'CcInputLegend' }, { ' accept', 'CcHint' } })
    end
    api.nvim_buf_set_extmark(s.input, ns_input, 0, 0, { virt_text = chunks, virt_text_pos = 'overlay' })
    return
  end
  local chunks = { { 'Type your prompt here... ', 'CcHint' } }
  local function add(key, what)
    if key then
      vim.list_extend(chunks, { { key, 'CcInputLegend' }, { (' %s '):format(what), 'CcHint' } })
    end
  end
  add(first(k.submit_insert), 'send')
  add('/', 'commands')
  add(first(k.mention), 'files')
  add(k.paste_image or nil, 'image')
  add(first(k.history_prev), 'history')
  api.nvim_buf_set_extmark(s.input, ns_input, 0, 0, { virt_text = chunks, virt_text_pos = 'overlay' })
end

--- Input height follows its text, between win.input_min and win.input_max of 'lines'
---@param p yacc.Panel
local function fit_input(p)
  local w = config.options.win
  local lo, hi = math.floor(vim.o.lines * w.input_min), math.floor(vim.o.lines * w.input_max)
  local h = api.nvim_win_text_height(p.input, {}).all
  api.nvim_win_set_height(p.input, math.max(lo, math.min(hi, h)))
end

---@param s yacc.Session
---@return boolean
local function active(s)
  return s.state == 'busy' or #s.held > 0 or #tasks.running(s) > 0
end

local function any_active()
  for _, s in pairs(session.sessions) do
    if active(s) then
      return true
    end
  end
  return false
end

local function update_timer()
  if any_active() then
    if not timer then
      timer = assert(vim.uv.new_timer())
      timer:start(0, 100, function()
        vim.schedule(function()
          frame = frame % #spinner + 1
          for _, s in pairs(session.sessions) do
            if active(s) then
              M.refresh(s, true)
            end
          end
        end)
      end)
    end
  elseif timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

--- Redraw the winbars of every panel that shows `s`
---@param s yacc.Session
---@param from_timer? boolean
function M.refresh(s, from_timer)
  tasks.draw(s, spinner[frame])
  for _, p in pairs(panels) do
    if valid(p.out) and api.nvim_win_get_buf(p.out) == s.out then
      api.nvim_set_option_value('winbar', out_winbar(s), { win = p.out, scope = 'local' })
      footer(p, s)
    end
  end
  if not from_timer then
    update_timer()
    M.show_queue(s)
  end
end

--- Placeholder, queue and height of the input, after its text changed
---@param s yacc.Session
function M.input_changed(s)
  if not api.nvim_buf_is_valid(s.input) then
    return
  end
  placeholder(s)
  for _, p in pairs(panels) do
    if valid(p.input) and api.nvim_win_get_buf(p.input) == s.input then
      fit_input(p)
    end
  end
end

--- Queued prompts, as grey user bubbles after the end of the output, where they will
--- show once the CLI takes them
---@param s yacc.Session
function M.show_queue(s)
  if #s.queue == 0 and #s.held == 0 then
    s.render:set_tail(nil)
    return
  end
  local bar = { require(root .. 'render').icons.border, 'CcMessageRoleUser' }
  local lines = {}
  for _, id in ipairs(vim.list_extend(vim.list_slice(s.queue), s.held)) do
    local c = s.cmds[id]
    for i, l in ipairs(vim.split(c.text, '\n', { plain = true })) do
      lines[#lines + 1] = { bar, { (i == 1 and '  ⏳ ' or '     ') .. l, 'CcHint' } }
    end
  end
  local edit, cancel = first(config.options.keys.history_prev), first(config.options.keys.interrupt)
  local legend
  if #s.held > 0 then
    legend = { bar, { '  ' }, { 'SENDING', 'CcQueued' } }
    if cancel then
      legend[#legend + 1] = { (' %s to cancel'):format(cancel), 'CcHint' }
    end
  else
    legend = { bar, { '  ' }, { 'QUEUED', 'CcQueued' } }
  end
  if edit then
    legend[#legend + 1] = { (' %s in the input to edit the last one'):format(edit), 'CcHint' }
  end
  lines[#lines + 1] = legend
  -- The footer covers the last row of the window
  lines[#lines + 1] = { { ' ' } }
  s.render:set_tail(lines)
end

---@param s yacc.Session
---@param lines string[]
local function set_input(s, lines)
  api.nvim_buf_set_lines(s.input, 0, -1, false, lines)
  for _, p in pairs(panels) do
    if valid(p.input) and api.nvim_win_get_buf(p.input) == s.input then
      api.nvim_win_set_cursor(p.input, { #lines, #lines[#lines] })
    end
  end
end

--- Take the last queued message back into the input, if the CLI has not delivered it
---@param s yacc.Session
local function edit_queued(s)
  ---@param text string
  local function take_back(text)
    local lines = vim.split(text, '\n', { plain = true })
    local cur = api.nvim_buf_get_lines(s.input, 0, -1, false)
    if #cur > 1 or cur[1] ~= '' then
      vim.list_extend(lines, cur)
    end
    set_input(s, lines)
    s:changed()
  end
  -- The newest message is the one still waiting out its send delay
  local held = s:cancel_held()
  if held then
    return take_back(held)
  end
  local id = s.queue[#s.queue]
  local c = s.cmds[id]
  s:request({ subtype = 'cancel_async_message', message_uuid = id }, function(resp)
    if not (resp.response or {}).cancelled then
      vim.notify 'Claude: the message was already sent'
      return
    end
    s:_unqueue(id)
    s.cmds[id] = nil
    take_back(c.text)
  end)
end

--- Cancel the newest message still waiting out its send delay. Its text goes back to
--- the input when the input is empty, else to the input history.
---@param s yacc.Session
function M.cancel_send(s)
  local text = s:cancel_held()
  if not text then
    return
  end
  local cur = api.nvim_buf_get_lines(s.input, 0, -1, false)
  if #cur == 1 and cur[1] == '' then
    set_input(s, vim.split(text, '\n', { plain = true }))
  else
    s.cancelled[#s.cancelled + 1] = text
    vim.notify(
      ('Claude: send cancelled, %s in the input history has it'):format(
        first(config.options.keys.history_prev) or 'the history'
      )
    )
  end
end

--- Walk the prompts of this session. The draft being typed comes back at the end.
---@param s yacc.Session
---@param dir -1|1
local function history(s, dir)
  -- Queued messages are not rendered yet, they come after the rendered prompts
  local prompts = vim.list_extend(vim.list_slice(s.render.prompts), s.cancelled)
  for _, id in ipairs(s.queue) do
    prompts[#prompts + 1] = s.cmds[id] and s.cmds[id].text
  end
  local h = s.history or { idx = #prompts + 1 }
  local idx = h.idx + dir
  if idx < 1 or idx > #prompts + 1 then
    return
  end
  if h.idx == #prompts + 1 then
    h.draft = api.nvim_buf_get_lines(s.input, 0, -1, false)
  end
  h.idx = idx
  s.history = h
  set_input(s, idx == #prompts + 1 and h.draft or vim.split(prompts[idx], '\n', { plain = true }))
end

--- Blink's menu keeps <Up> and <Down> while it is open
---@param dir -1|1
---@return boolean
local function completion_select(dir)
  local ok, blink = pcall(require, 'blink.cmp')
  if not ok or not blink.is_menu_visible() then
    return false
  end
  if dir < 0 then
    blink.select_prev()
  else
    blink.select_next()
  end
  return true
end

function M.hide()
  local tab = api.nvim_get_current_tabpage()
  local p = panels[tab]
  panels[tab] = nil
  if not p then
    return
  end
  for _, win in ipairs { p.footer, p.input, p.out } do
    if valid(win) then
      -- Fails when the panel is the last window of the last tabpage
      pcall(api.nvim_win_close, win, false)
    end
  end
end

--- Text width of an output window
---@param win integer
---@return integer
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

---@return integer
local function width()
  local w = config.options.win.width
  return w < 1 and math.floor(vim.o.columns * w) or w
end

---@param s yacc.Session
---@param opts? {enter?: boolean, insert?: boolean}
function M.show(s, opts)
  opts = opts or { enter = true, insert = true }
  session.current = s.id
  local p = panel()
  if not p then
    M.hide()
    local out = api.nvim_open_win(s.out, false, { split = 'right', win = -1, width = width() })
    local input = api.nvim_open_win(s.input, false, {
      split = 'below',
      win = out,
      height = math.floor(vim.o.lines * config.options.win.input_min),
    })
    p = { out = out, input = input }
    panels[api.nvim_get_current_tabpage()] = p
  else
    api.nvim_win_set_buf(p.out, s.out)
    api.nvim_win_set_buf(p.input, s.input)
  end
  set_wo(p.out, out_wo())
  set_wo(p.input, in_wo())
  -- The panel can come back at another width than the tables were fitted to
  s.render:reflow_tables(text_width(p.out))
  -- A buffer swapped into the window can keep fold levels from before its fold marks
  -- existed. Compute them again, this also applies foldlevel to the new buffer.
  api.nvim_win_call(p.out, function()
    vim.cmd 'silent! normal! zx'
  end)
  M.input_changed(s)
  api.nvim_win_set_cursor(p.out, { api.nvim_buf_line_count(s.out), 0 })
  M.refresh(s)
  if opts.enter then
    api.nvim_set_current_win(p.input)
    if opts.insert then
      vim.cmd 'startinsert!'
    end
  end
  require(root .. 'permission').resume(s)
end

---@param s yacc.Session
---@return boolean
function M.is_shown(s)
  local p = panel()
  return p ~= nil and api.nvim_win_get_buf(p.out) == s.out
end

--- Stop a session, hide its panel and wipe its buffers
---@param s yacc.Session
function M.close(s)
  -- Insert mode would carry over to the window that gets the focus
  vim.cmd.stopinsert()
  if M.is_shown(s) then
    M.hide()
  end
  s:close()
end

---@param s yacc.Session
--- Set the model, or pick one from the list the CLI returned at initialize
---@param s yacc.Session
---@param model string Empty to pick
function M.model(s, model)
  if model ~= '' then
    -- The CLI takes any string here, but only restores the models of its own list on
    -- resume, so stay within that list
    local known = {}
    for _, m in ipairs(s.models) do
      if model == m.value or model == m.resolvedModel then
        return s:set_model(m.value)
      end
      known[#known + 1] = m.value
    end
    if #known > 0 then
      vim.notify(
        ('Claude: unknown model %s, use one of: %s'):format(model, table.concat(known, ', ')),
        vim.log.levels.WARN
      )
      return
    end
    return s:set_model(model)
  end
  if #s.models == 0 then
    return vim.ui.input({ prompt = 'Model: ' }, function(m)
      if m and m ~= '' then
        s:set_model(m)
      end
    end)
  end
  vim.ui.select(s.models, {
    prompt = 'Model',
    format_item = function(m)
      return ('%s  %s'):format(m.displayName or m.value, m.description or '')
    end,
  }, function(m)
    if m then
      s:set_model(m.value)
    end
  end)
end

M.modes = { 'auto', 'default', 'acceptEdits', 'plan', 'dontAsk', 'bypassPermissions' }

--- Set the permission mode, or pick one
---@param s yacc.Session
---@param mode string Empty to pick
function M.mode(s, mode)
  if mode ~= '' then
    return s:set_mode(mode)
  end
  vim.ui.select(M.modes, {
    prompt = 'Permission mode',
    format_item = function(m)
      return m == s.permission_mode and m .. ' (current)' or m
    end,
  }, function(m)
    if m then
      s:set_mode(m)
    end
  end)
end

---@class yacc.LocalCommand
---@field desc string Shown in the completion menu
---@field arg? string Argument hint
---@field fn fun(s: cc.Session, arg: string)

--- Slash commands the plugin answers itself instead of sending them to the CLI
---@type table<string, yacc.LocalCommand>
M.builtin_commands = {
  model = { desc = 'Pick the model, or set it', arg = '[model]', fn = M.model },
  mode = { desc = 'Pick the permission mode, or set it', arg = '[mode]', fn = M.mode },
  search = {
    desc = 'Fuzzy search the prompts and answers of past sessions, `all` for every project',
    arg = '[all]',
    fn = function(_, arg)
      require(root .. 'picker').search(arg == 'all')
    end,
  },
  resume = {
    desc = 'Pick a session of this repository, `all` for every project',
    arg = '[all]',
    fn = function(_, arg)
      require(root .. 'picker').sessions(arg == 'all')
    end,
  },
  ['remote-control'] = {
    desc = 'Continue the session from claude.ai or the mobile app, `off` turns it off',
    arg = '[off]',
    fn = function(s, arg)
      s:set_remote(arg ~= 'off')
    end,
  },
  rc = {
    desc = 'Alias of /remote-control',
    arg = '[off]',
    fn = function(s, arg)
      s:set_remote(arg ~= 'off')
    end,
  },
  tasks = {
    desc = 'Running shells and subagents of this session, stop one with ' .. (config.options.keys.stop_task or ''),
    fn = function(s)
      require(root .. 'picker').tasks(s)
    end,
  },
  clear = {
    desc = 'Start a new conversation in this session',
    fn = function(s)
      s:clear()
    end,
  },
  ['close-session'] = { desc = 'Stop this session and wipe its buffers', fn = M.close },
  close = { desc = 'Alias of /close-session', fn = M.close },
}

---@param s yacc.Session
---@return boolean
local function input_empty(s)
  local lines = api.nvim_buf_get_lines(s.input, 0, -1, false)
  return #lines == 1 and lines[1] == ''
end

--- Offer the suggested prompt through blink, when the empty input is being typed in
---@param s yacc.Session
function M.suggest(s)
  if not api.nvim_buf_is_valid(s.input) then
    return
  end
  placeholder(s)
  if
    not s.suggestion
    or api.nvim_get_current_buf() ~= s.input
    or not input_empty(s)
    or not api.nvim_get_mode().mode:match '^i'
  then
    return
  end
  local ok, blink = pcall(require, 'blink.cmp')
  if ok then
    blink.show { providers = { require(root .. 'blink').provider } }
  end
end

--- Put the suggested prompt in the empty input
---@param s yacc.Session
---@return boolean
function M.accept_suggestion(s)
  if not s.suggestion or not input_empty(s) then
    return false
  end
  api.nvim_buf_set_lines(s.input, 0, -1, false, { s.suggestion })
  return true
end

--- Built-in commands, overridden or extended by the `commands` option
---@return table<string, yacc.LocalCommand>
function M.local_commands()
  return vim.tbl_extend('force', M.builtin_commands, config.options.commands)
end

local group = api.nvim_create_augroup('cc.ui', { clear = true })

api.nvim_create_autocmd('WinScrolled', {
  group = group,
  callback = function()
    for _, p in pairs(panels) do
      if valid(p.out) and vim.v.event[tostring(p.out)] then
        local s = session.from_buf(api.nvim_win_get_buf(p.out))
        if s then
          footer(p, s)
        end
      end
    end
  end,
})

api.nvim_create_autocmd('WinResized', {
  group = group,
  callback = function()
    for _, p in pairs(panels) do
      if valid(p.out) then
        local s = session.from_buf(api.nvim_win_get_buf(p.out))
        if s then
          footer(p, s)
          s.render:reflow_tables(text_width(p.out))
        end
      end
    end
  end,
})

---@param s yacc.Session
function M.submit(s)
  local text = table.concat(api.nvim_buf_get_lines(s.input, 0, -1, false), '\n')
  if vim.trim(text) == '' then
    return
  end
  api.nvim_buf_set_lines(s.input, 0, -1, false, {})
  s.history = nil
  local name, arg = text:match '^%s*/(%S+)%s*(.-)%s*$'
  local cmd = name and M.local_commands()[name]
  if cmd then
    return cmd.fn(s, arg)
  end
  -- Sending always brings the output to its end, like scrolling to your own message
  for _, win in ipairs(vim.fn.win_findbuf(s.out)) do
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(s.out), 0 })
  end
  s:submit(text)
end

--- Insert text at a position of the input buffer and resume insert mode after it
---@param s yacc.Session
---@param pos integer[] (1,0)-indexed cursor
---@param text string
function M.insert(s, pos, text)
  local p = panel()
  if not p then
    M.show(s, { enter = false })
    p = assert(panel())
  end
  local row, col = pos[1] - 1, pos[2]
  api.nvim_buf_set_text(s.input, row, col, row, col, { text })
  api.nvim_set_current_win(p.input)
  api.nvim_win_set_cursor(p.input, { row + 1, col + #text })
  local line = api.nvim_buf_get_lines(s.input, row, row + 1, false)[1]
  vim.cmd(col + #text >= #line and 'startinsert!' or 'startinsert')
end

--- Append text to the end of the input buffer
---@param s yacc.Session
---@param text string
function M.append(s, text)
  local last = api.nvim_buf_get_lines(s.input, -2, -1, false)[1] or ''
  local sep = (last == '' or last:match '%s$') and '' or ' '
  local n = api.nvim_buf_line_count(s.input)
  api.nvim_buf_set_text(s.input, n - 1, #last, n - 1, #last, { sep .. text .. ' ' })
end

---@param s yacc.Session
local function attach(s)
  local k = config.options.keys
  local function map(buf, modes, keys, fn, desc)
    for _, key in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set(modes, key, fn, { buffer = buf, desc = desc })
    end
  end

  map(s.input, 'i', k.submit_insert, function()
    M.submit(s)
  end, 'Claude: send')
  map(s.input, 'n', k.submit_normal, function()
    M.submit(s)
  end, 'Claude: send')
  -- A single stray press must not cost a session
  local armed = {}
  local function twice(name, key, msg, fn, when)
    return function()
      if when and not when() then
        return key
      end
      local now = vim.uv.now()
      if armed[name] and now - armed[name] < k.double_press_ms then
        armed[name] = nil
        vim.schedule(fn)
      else
        armed[name] = now
        vim.schedule(function()
          vim.notify(msg)
        end)
      end
      return ''
    end
  end
  for _, buf in ipairs { s.input, s.out } do
    -- Only while a turn runs, otherwise the key keeps its own meaning
    for _, key in ipairs(k.interrupt) do
      vim.keymap.set({ 'n', 'i' }, key, function()
        -- During the send delay the key cancels the send, not the turn
        if #s.held > 0 then
          vim.schedule(function()
            M.cancel_send(s)
          end)
          return ''
        elseif s.state ~= 'busy' then
          return key
        end
        vim.schedule(function()
          s:interrupt()
        end)
        return ''
      end, { buffer = buf, expr = true, desc = 'Claude: cancel the send or interrupt' })
    end
    for _, key in ipairs(k.close) do
      vim.keymap.set(
        { 'n', 'i' },
        key,
        twice('close', key, 'Claude: press ' .. key .. ' again to close the session', function()
          M.close(s)
        end),
        { buffer = buf, expr = true, desc = 'Claude: close session (press twice)' }
      )
    end
  end
  map(s.out, 'n', k.hide, M.hide, 'Claude: hide')
  map(s.input, 'i', k.window, '<C-\\><C-n><C-w>', 'Claude: window command')

  local function nav(dir, key)
    return function()
      if vim.fn.mode() == 'i' and completion_select(dir) then
        return ''
      end
      local row = api.nvim_win_get_cursor(0)[1]
      local edge = dir < 0 and row == 1 or dir > 0 and row == api.nvim_buf_line_count(s.input)
      if not edge then
        return key
      end
      vim.schedule(function()
        if dir < 0 and (#s.queue > 0 or #s.held > 0) then
          edit_queued(s)
        else
          history(s, dir)
        end
      end)
      return ''
    end
  end
  require(root .. 'marks').attach(s, k)

  -- Rewriting the input also moves the queue mark off the first line
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = s.input,
    callback = function()
      M.input_changed(s)
    end,
  })
  -- A command sent from insert mode can open a picker, blink keeps its menu over it
  api.nvim_create_autocmd('WinLeave', {
    buffer = s.input,
    callback = function()
      local ok, blink = pcall(require, 'blink.cmp')
      if ok and blink.is_menu_visible() then
        blink.hide()
      end
    end,
  })
  api.nvim_create_autocmd('InsertEnter', {
    buffer = s.input,
    callback = function()
      vim.schedule(function()
        M.suggest(s)
      end)
    end,
  })
  -- blink's ghost text takes the place of the suggestion in the placeholder
  api.nvim_create_autocmd('User', {
    pattern = { 'BlinkCmpMenuOpen', 'BlinkCmpMenuClose' },
    callback = function(ev)
      if not api.nvim_buf_is_valid(s.input) then
        return true
      end
      if api.nvim_get_current_buf() == s.input and s.suggestion then
        if ev.match == 'BlinkCmpMenuOpen' then
          api.nvim_buf_clear_namespace(s.input, ns_input, 0, -1)
        else
          placeholder(s)
        end
      end
    end,
  })
  if k.accept_suggestion then
    local key = k.accept_suggestion
    local function accept()
      if not M.accept_suggestion(s) then
        api.nvim_feedkeys(vim.keycode(key), 'n', false)
        return
      end
      if api.nvim_get_mode().mode:match '^i' then
        api.nvim_win_set_cursor(0, { 1, #s.suggestion })
      else
        vim.cmd 'startinsert!'
      end
    end
    vim.keymap.set('n', key, accept, { buffer = s.input, desc = 'Claude: take the suggested prompt' })
    -- In insert mode the key belongs to blink, which shows the suggestion as an item
    if not pcall(require, 'blink.cmp') then
      vim.keymap.set('i', key, accept, { buffer = s.input, desc = 'Claude: take the suggested prompt' })
    end
  end
  for _, key in ipairs(k.history_prev) do
    vim.keymap.set(
      { 'n', 'i' },
      key,
      nav(-1, key),
      { buffer = s.input, expr = true, desc = 'Claude: edit queued or previous prompt' }
    )
  end
  for _, key in ipairs(k.history_next) do
    vim.keymap.set({ 'n', 'i' }, key, nav(1, key), { buffer = s.input, expr = true, desc = 'Claude: next prompt' })
  end
  map(s.out, 'n', k.focus_input, function()
    local p = panel()
    if p then
      api.nvim_set_current_win(p.input)
      vim.cmd 'startinsert!'
    end
  end, 'Claude: focus input')

  if k.paste_image then
    -- Without an image in the clipboard the key keeps its own meaning
    vim.keymap.set('i', k.paste_image, function()
      local img, err = require(root .. 'image').from_clipboard()
      if not img then
        if err then
          vim.schedule(function()
            vim.notify('Claude: ' .. err, vim.log.levels.WARN)
          end)
        end
        return k.paste_image
      end
      s.images[#s.images + 1] = img
      return ('[Image #%d]'):format(#s.images)
    end, { buffer = s.input, expr = true, desc = 'Claude: paste clipboard image' })
  end

  if k.mention then
    vim.keymap.set('i', k.mention, function()
      local pos = api.nvim_win_get_cursor(0)
      local before = api.nvim_get_current_line():sub(1, pos[2])
      -- Leave "user@host" alone, mentions start a word
      if before ~= '' and not before:match '%s$' then
        return k.mention
      end
      vim.schedule(function()
        vim.cmd.stopinsert()
        require(root .. 'picker').files(s.cwd, function(paths)
          M.insert(s, pos, table.concat(
            vim.tbl_map(function(path)
              return '@' .. path
            end, paths),
            ' '
          ) .. ' ')
        end)
      end)
      return ''
    end, { buffer = s.input, expr = true, desc = 'Claude: mention a file' })
  end
end

---@param buf integer
---@param ranged boolean
---@param line1 integer
---@param line2 integer
---@return string
function M.mention_of(buf, ranged, line1, line2)
  local s = M.current()
  local path = api.nvim_buf_get_name(buf)
  local rel = s and vim.fs.relpath(s.cwd, path) or nil
  -- Outside the session, absolute: the CLI does not expand '~'
  path = rel or vim.fn.fnamemodify(path, ':p')
  if not ranged then
    return '@' .. path
  end
  return ('@%s#L%d-%d'):format(path, line1, line2)
end

---@param opts? yacc.NewOpts
---@return yacc.Session
function M.create(opts)
  if config.options.blink then
    require(root .. 'blink').register()
  end
  local s = session.new(opts)
  attach(s)
  return s
end

---@param count integer
function M.toggle(count)
  if count > 0 then
    local s = session.sessions[count]
    if s and M.is_shown(s) then
      return M.hide()
    end
    if not s then
      s = M.create { id = count }
      s:start()
    end
    return M.show(s)
  end
  if panel() then
    return M.hide()
  end
  local s = M.current()
  if not s then
    s = M.create()
    s:start()
  end
  M.show(s)
end

--- Path of the transcript the CLI writes for this session
---@param s yacc.Session
---@return string?
function M.transcript(s)
  if not s.session_id then
    return nil
  end
  return vim.fs.joinpath(require(root .. 'history').project_dir(s.cwd), s.session_id .. '.jsonl')
end

--- Rebuild the output from the transcript, with its marks and folds
---@param s yacc.Session
function M.rerender(s)
  if not session.sessions[s.id] then
    return
  end
  local path = M.transcript(s)
  -- A reload (`:edit`) detaches the parser and the highlighter from the buffer
  if not vim.treesitter.highlighter.active[s.out] then
    pcall(vim.treesitter.start, s.out, 'markdown')
  end
  s:reset_output()
  if path and vim.uv.fs_stat(path) then
    require(root .. 'history').load(path, s.render)
    require(root .. 'marks').restore(s)
  end
  for _, win in ipairs(vim.fn.win_findbuf(s.out)) do
    set_wo(win, out_wo())
    api.nvim_win_call(win, function()
      vim.cmd 'silent! normal! zx'
    end)
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(s.out), 0 })
  end
end

--- Rebuild the output from the transcript and restart the stream process
---@param s yacc.Session
function M.reload(s)
  M.rerender(s)
  s:start()
end

--- Hand the session to an interactive `claude --resume`, for commands that only the
--- TUI has. Two processes on one session would both append to its transcript, so
--- the stream process stops first and comes back when the terminal exits.
---@param s yacc.Session
function M.term(s)
  if not s.session_id then
    vim.notify('Claude: send a first message before opening the session in a terminal', vim.log.levels.WARN)
    return
  end
  local o = config.options
  local cmd = vim.list_extend(vim.list_slice(o.cmd), { '--resume', s.session_id })
  -- The chat's model and mode, the CLI would not restore a model it does not know
  if s.model or o.model then
    vim.list_extend(cmd, { '--model', s.model or o.model })
  end
  if s.permission_mode or o.permission_mode then
    vim.list_extend(cmd, { '--permission-mode', s.permission_mode or o.permission_mode })
  end
  -- A job's env adds to the environment, removing a variable takes env(1)
  if not o.allow_api_key then
    cmd = vim.list_extend({ 'env', '-u', 'ANTHROPIC_API_KEY' }, cmd)
  end
  -- jobstart() takes an empty table as a list and fails with E475
  local env = next(o.env) and vim.deepcopy(o.env) or nil
  s:stop_then(function()
    M.hide()
    local buf
    local ok, snacks = pcall(require, 'snacks')
    if ok and snacks.terminal then
      local term = snacks.terminal.open(cmd, {
        cwd = s.cwd,
        env = env,
        win = { position = 'right', width = o.win.width },
      })
      buf = term.buf
    else
      vim.cmd 'botright vnew'
      vim.fn.jobstart(cmd, { term = true, cwd = s.cwd, env = env })
      buf = api.nvim_get_current_buf()
      vim.cmd.startinsert()
    end
    api.nvim_create_autocmd('TermClose', {
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(function()
          M.reload(s)
        end)
      end,
    })
  end)
end

return M
