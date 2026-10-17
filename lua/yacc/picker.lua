--- Session and file pickers: Snacks when it is installed, vim.ui otherwise

local api = vim.api
local root = (...):match '^(.*%.)'
local config = require(root .. 'config')
local session = require(root .. 'session')
local history = require(root .. 'history')
local render = require(root .. 'render')

local M = {}

---@return table?
local function snacks_picker()
  local ok, snacks = pcall(require, 'snacks')
  return ok and snacks.picker or nil
end

---@class cc.PickItem
---@field text string
---@field live? integer Session id. Snacks deep-copies items, a session holds userdata
---@field past? cc.HistoryItem
---@field target? cc.Target Message to scroll to, the end when nil
---@field wo? table<string, any> Preview window options, applied by Snacks

---@class cc.Target
---@field prompt integer
---@field kind 'user'|'assistant'
---@field line string First line of the message

---@param id string Claude session uuid
---@return cc.Session?
local function live_by_id(id)
  for _, s in pairs(session.sessions) do
    if s.session_id == id then
      return s
    end
  end
end

--- Resume a past session, or show it when it is already live
---@param h cc.HistoryItem
---@param opts? {enter?: boolean, insert?: boolean}
---@return cc.Session
local function resume(h, opts)
  local ui = require(root .. 'ui')
  local s = live_by_id(h.id)
  if not s then
    s = ui.create { resume = h.id, title = h.title, cwd = h.cwd }
    s.model = history.last_model(h.path)
    history.load(h.path, s.render)
    require(root .. 'marks').restore(s)
    s:start()
  end
  ui.show(s, opts)
  return s
end

---@param item cc.PickItem
local function open(item)
  if item.live then
    local s = session.sessions[item.live]
    return s and require(root .. 'ui').show(s)
  end
  resume(assert(item.past))
end

--- Row of a message in a rendered output buffer, 0-based. User messages are found by
--- their prompt mark, answers by their first line inside the prompt's turn.
---@param r cc.Render
---@param target cc.Target
---@return integer
local function locate(r, target)
  local rows = {}
  for _, id in ipairs(r.prompt_marks) do
    local pos = api.nvim_buf_get_extmark_by_id(r.buf, render.ns_block, id, {})
    rows[#rows + 1] = pos[1]
  end
  local base = rows[target.prompt] or 0
  if target.kind == 'user' then
    return base
  end
  local stop = rows[target.prompt + 1] or api.nvim_buf_line_count(r.buf)
  for i, l in ipairs(api.nvim_buf_get_lines(r.buf, base, stop, false)) do
    if l == target.line then
      return base + i - 1
    end
  end
  return base
end

---@type table<string, {buf: integer, r: cc.Render, mtime: integer, size: integer}>
local rendered_cache = {}

--- A transcript rendered like the output window, for previews. Kept until the picker
--- closes, or until the file changes.
---@param path string
---@return {buf: integer, r: cc.Render}
local function rendered(path)
  local stat = assert(vim.uv.fs_stat(path))
  local c = rendered_cache[path]
  if c and api.nvim_buf_is_valid(c.buf) and c.mtime == stat.mtime.sec and c.size == stat.size then
    return c
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'cc-output'
  pcall(vim.treesitter.start, buf, 'markdown')
  local r = render.new(buf, session.render_opts())
  history.load(path, r)
  vim.bo[buf].modifiable = false
  c = { buf = buf, r = r, mtime = stat.mtime.sec, size = stat.size }
  rendered_cache[path] = c
  return c
end

local function drop_rendered()
  for _, c in pairs(rendered_cache) do
    render.by_buf[c.buf] = nil
    pcall(api.nvim_buf_delete, c.buf, { force = true })
  end
  rendered_cache = {}
end

--- Snacks previewer: the rendered conversation, at the target message or at its end
---@param ctx table snacks.picker.preview.ctx
local function preview(ctx)
  local item = ctx.item
  local buf, row
  if item.live then
    local s = session.sessions[item.live]
    if not s then
      return
    end
    buf = s.out
  else
    local c = rendered(item.past.path)
    buf = c.buf
    row = item.target and locate(c.r, item.target)
  end
  ctx.preview:set_buf(buf)
  local win = ctx.win
  row = row or (api.nvim_buf_line_count(buf) - 1)
  api.nvim_win_set_cursor(win, { row + 1, 0 })
  api.nvim_win_call(win, function()
    vim.cmd 'silent! normal! zx'
    vim.fn.winrestview { topline = math.max(1, row - 2) }
  end)
  local ok, rm = pcall(require, 'render-markdown')
  if ok and rm.render then
    pcall(rm.render, { buf = buf, win = win })
  end
end

--- Where a past session ran, when not in the current directory
---@param h cc.HistoryItem
---@return string?
local function place(h)
  if h.cwd == vim.fn.getcwd() then
    return nil
  end
  return vim.fn.fnamemodify(h.cwd, ':~')
end

---@param all boolean
---@return cc.PickItem[]
local function items(all)
  local list = {}
  local live = {}
  for _, s in ipairs(session.list()) do
    if s.session_id then
      live[s.session_id] = true
    end
    list[#list + 1] = {
      text = ('#%d %s'):format(s.id, s.title or 'new session'),
      live = s.id,
      wo = require(root .. 'ui').preview_wo(),
    }
  end
  for _, h in ipairs(history.list(vim.fn.getcwd(), config.options.history_limit, all)) do
    if not live[h.id] then
      local date = os.date('%Y-%m-%d %H:%M', h.mtime)
      list[#list + 1] = {
        text = ('%s %s %s'):format(date, h.title, place(h) or ''),
        past = h,
        wo = require(root .. 'ui').preview_wo(),
      }
    end
  end
  return list
end

--- Live sessions, then past ones from every worktree of the current repository
---@param all? boolean Past sessions of every project
function M.sessions(all)
  local list = items(all or false)
  if #list == 0 then
    vim.notify(all and 'Claude: no session' or 'Claude: no session for this repository')
    return
  end
  local picker = snacks_picker()
  if not picker then
    return vim.ui.select(list, {
      prompt = 'Claude sessions',
      format_item = function(item)
        return (item.live and '● ' or '  ') .. item.text
      end,
    }, function(item)
      if item then
        open(item)
      end
    end)
  end
  picker.pick {
    source = 'claude_sessions',
    title = all and 'Claude Sessions (all projects)' or 'Claude Sessions (<C-a> all projects)',
    items = list,
    preview = preview,
    on_close = drop_rendered,
    actions = {
      toggle_all = function(p)
        p:close()
        vim.schedule(function()
          M.sessions(not all)
        end)
      end,
    },
    win = { input = { keys = { ['<C-a>'] = { 'toggle_all', mode = { 'n', 'i' } } } } },
    format = function(item)
      local s = item.live and session.sessions[item.live]
      if s then
        return {
          { '● ', s.state == 'busy' and 'DiagnosticInfo' or 'DiagnosticOk' },
          { ('#%d '):format(s.id), 'Number' },
          { s.title or 'new session' },
          { ' ' .. s.state, 'Comment' },
        }
      end
      local where = place(item.past)
      return {
        { '  ' },
        {
          os.date('%Y-%m-%d %H:%M ', item.past.mtime) --[[@as string]],
          'Comment',
        },
        { item.past.title },
        { where and ('  ' .. where) or '', 'Comment' },
      }
    end,
    confirm = function(p, item)
      p:close()
      if item then
        open(item)
      end
    end,
  }
end

--- Fuzzy search in the prompts and answers of past sessions. Confirming resumes the
--- session and jumps to the message.
---@param all? boolean Sessions of every project, not only this repository
function M.search(all)
  local picker = snacks_picker()
  if not picker then
    vim.notify('Claude: search needs snacks.nvim', vim.log.levels.WARN)
    return
  end
  local list = {}
  local wo = require(root .. 'ui').preview_wo()
  for _, h in ipairs(history.list(vim.fn.getcwd(), config.options.history_limit, all)) do
    for _, m in ipairs(history.messages(h.path)) do
      local first = ''
      for l in m.text:gmatch '[^\n]+' do
        if vim.trim(l) ~= '' then
          first = l
          break
        end
      end
      list[#list + 1] = {
        text = m.text:gsub('%s+', ' '):sub(1, 400),
        past = h,
        ts = m.ts or h.mtime,
        target = { prompt = m.prompt, kind = m.kind, line = m.kind == 'user' and '' or first },
        wo = wo,
      }
    end
  end
  table.sort(list, function(a, b)
    return a.ts > b.ts
  end)
  picker.pick {
    source = 'claude_search',
    title = all and 'Claude Search (all projects)' or 'Claude Search (<C-a> all projects)',
    items = list,
    preview = preview,
    on_close = drop_rendered,
    format = function(item)
      local user = item.target.kind == 'user'
      return {
        {
          os.date('%m-%d %H:%M ', item.ts) --[[@as string]],
          'Comment',
        },
        { user and '▌ ' or '  ', user and 'CcMessageRoleUser' or 'CcMessageRoleAssistant' },
        { item.text },
        { '  ' .. item.past.title, 'Comment' },
      }
    end,
    actions = {
      toggle_all = function(p)
        p:close()
        vim.schedule(function()
          M.search(not all)
        end)
      end,
    },
    win = { input = { keys = { ['<C-a>'] = { 'toggle_all', mode = { 'n', 'i' } } } } },
    confirm = function(p, item)
      p:close()
      if not item then
        return
      end
      vim.schedule(function()
        local s = resume(item.past, { enter = false })
        local win = vim.fn.win_findbuf(s.out)[1]
        if win then
          api.nvim_set_current_win(win)
          require(root .. 'marks').goto_row(locate(s.render, item.target))
        end
      end)
    end,
  }
end

--- Generic list picker with a markdown preview, Snacks or vim.ui.select
---@param title string
---@param list {text: string, preview: {text: string, ft: string}}[]
---@param confirm fun(item: table)
---@param keys? table<string, {fn: fun(item: table), desc: string}> Extra keys, Snacks only
local function pick(title, list, confirm, keys)
  if #list == 0 then
    vim.notify(('Claude: no %s'):format(title:lower()))
    return
  end
  local picker = snacks_picker()
  if not picker then
    return vim.ui.select(list, {
      prompt = title,
      format_item = function(item)
        return item.text
      end,
    }, function(item)
      if item then
        confirm(item)
      end
    end)
  end
  local actions, win_keys = {}, {}
  for key, a in pairs(keys or {}) do
    actions[a.desc] = function(p, item)
      if item then
        a.fn(item)
        p:close()
      end
    end
    win_keys[key] = { a.desc, mode = { 'n', 'i' }, desc = a.desc }
  end
  picker.pick {
    source = 'claude_' .. title:lower(),
    title = title,
    items = list,
    preview = 'preview',
    format = 'text',
    actions = actions,
    win = { input = { keys = win_keys }, list = { keys = win_keys } },
    confirm = function(p, item)
      p:close()
      if item then
        vim.schedule(function()
          confirm(item)
        end)
      end
    end,
  }
end

--- Show the session and put the cursor of its output window on a row
---@param id integer Session id
---@param row integer 0-based
local function jump_to(id, row)
  local s = session.sessions[id]
  if not s then
    return
  end
  local ui = require(root .. 'ui')
  if not ui.is_shown(s) then
    ui.show(s, { enter = false })
  end
  local win = vim.fn.win_findbuf(s.out)[1]
  if win then
    api.nvim_set_current_win(win)
    require(root .. 'marks').goto_row(row)
  end
end

--- Lines of the output from `from` up to the row before `to`
---@param s cc.Session
---@param from integer
---@param to integer
---@return string
local function excerpt(s, from, to)
  return table.concat(api.nvim_buf_get_lines(s.out, math.max(0, from), to, false), '\n')
end

--- Prompts of the session, the preview shows the answer
---@param s cc.Session
function M.prompts(s)
  local rows = require(root .. 'marks').prompt_rows(s)
  local list = {}
  for i, row in ipairs(rows) do
    local next_row = rows[i + 1] and rows[i + 1] - 3 or api.nvim_buf_line_count(s.out)
    local first = api.nvim_buf_get_lines(s.out, row, row + 1, false)[1] or ''
    list[#list + 1] = {
      text = ('%d. %s'):format(i, first),
      sid = s.id,
      row = row,
      preview = { text = excerpt(s, row, next_row), ft = 'markdown' },
    }
  end
  pick('Prompts', list, function(item)
    jump_to(item.sid, item.row)
  end)
end

--- Shells and subagents of the session, running ones first. The preview shows the
--- output file of the task, or its block in the output.
---@param s cc.Session
function M.tasks(s)
  local tasks = require(root .. 'tasks')
  local icons = { running = '⠿', completed = '✓', failed = '✗', stopped = '■' }
  -- Running ones first, newest first in each group
  local order, done = {}, {}
  for i = #s.task_order, 1, -1 do
    local t = s.tasks[s.task_order[i]]
    table.insert(t.status == 'running' and order or done, t)
  end
  vim.list_extend(order, done)
  local list = {}
  for _, t in ipairs(order) do
    local row, tail = s.render:_block_pos(t.id)
    local took = tasks.elapsed((t.ended or vim.uv.now()) - t.started)
    local text, ft
    if t.output_file and vim.fn.filereadable(t.output_file) == 1 then
      local lines = vim.fn.readfile(t.output_file, '', -200)
      text, ft = table.concat(lines, '\n'), t.kind == 'shell' and 'sh' or 'markdown'
    else
      text, ft = row and excerpt(s, row, tail + 1) or t.description, 'markdown'
    end
    list[#list + 1] = {
      text = ('%s %-5s %6s  %s%s'):format(icons[t.status], t.kind, took, t.description, t.background and ' (bg)' or ''),
      sid = s.id,
      row = row,
      task = t.id,
      preview = { text = text, ft = ft },
    }
  end
  pick('Tasks', list, function(item)
    if item.row then
      jump_to(item.sid, item.row)
    end
  end, {
    [config.options.keys.stop_task] = {
      desc = 'stop_task',
      fn = function(item)
        local live = session.sessions[item.sid]
        local t = live and live.tasks[item.task]
        if not t or t.status ~= 'running' then
          return vim.notify 'Claude: this task is not running'
        elseif not t.task_id then
          return vim.notify(
            'Claude: the CLI did not report this one as a task, interrupt the turn instead',
            vim.log.levels.WARN
          )
        end
        live:request { subtype = 'stop_task', task_id = t.task_id }
      end,
    },
  })
end

--- Marks of the session's output buffer
---@param s cc.Session
function M.marks(s)
  local list = {}
  for c in ('abcdefghijklmnopqrstuvwxyz'):gmatch '.' do
    local m = api.nvim_buf_get_mark(s.out, c)
    if m[1] > 0 then
      local row = m[1] - 1
      local line = api.nvim_buf_get_lines(s.out, row, row + 1, false)[1] or ''
      list[#list + 1] = {
        text = ("'%s  %s"):format(c, vim.trim(line)),
        sid = s.id,
        row = row,
        preview = { text = excerpt(s, row - 5, row + 20), ft = 'markdown' },
      }
    end
  end
  pick('Marks', list, function(item)
    jump_to(item.sid, item.row)
  end)
end

--- Pick one or more files, paths relative to `cwd`
---@param cwd string
---@param cb fun(paths: string[])
function M.files(cwd, cb)
  local picker = snacks_picker()
  if not picker then
    return vim.ui.input({ prompt = 'File: ', completion = 'file' }, function(path)
      if path and path ~= '' then
        cb { path }
      end
    end)
  end
  picker.files {
    cwd = cwd,
    confirm = function(p)
      local paths = {}
      -- A picker config can move the root out of the project, those files stay absolute
      local base = vim.fs.normalize(cwd) .. '/'
      for _, item in ipairs(p:selected { fallback = true }) do
        local path = vim.fs.normalize(picker.util.path(item) or item.file)
        paths[#paths + 1] = vim.startswith(path, base) and path:sub(#base + 1) or path
      end
      p:close()
      if #paths > 0 then
        vim.schedule(function()
          cb(paths)
        end)
      end
    end,
  }
end

return M
