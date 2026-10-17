--- Writes a Claude conversation into the output buffer, with the layout of opencode.nvim.
--- The text is plain markdown. Headers, gutter bars and diff gutters are extmarks.
---
--- Every message starts with `----`, a header row and a blank spacer. Every part (text,
--- tool, note) ends with one blank line, so the buffer always ends with ''.

local api = vim.api
local root = (...):match '^(.*%.)'
local tables = require(root .. 'table')

-- Fold ranges only, foldexpr reads every mark in them. The output window has
-- foldlevel=1: folds in `ns` are level 2 and start closed, folds in `ns_open` are
-- level 1 and start open.
local ns = api.nvim_create_namespace 'cc.render'
local ns_open = api.nvim_create_namespace 'cc.render.open'
-- Headers, bars, diff gutters
local ns_deco = api.nvim_create_namespace 'cc.render.deco'
-- Extent of each tool block, to insert its result later
local ns_block = api.nvim_create_namespace 'cc.render.block'
-- Extent of each markdown table in answers, to fit it again when the width changes
local ns_table = api.nvim_create_namespace 'cc.render.table'
-- Live state of shells and subagents, after their title
local ns_status = api.nvim_create_namespace 'cc.render.status'
-- Queued prompts, virtual lines after the last row
local ns_tail = api.nvim_create_namespace 'cc.render.tail'

local M = {}

M.ns = ns
M.ns_open = ns_open
M.ns_deco = ns_deco
M.ns_block = ns_block
M.ns_table = ns_table
M.ns_status = ns_status
M.ns_tail = ns_tail

--- Renderer of each output buffer, for foldtext
---@type table<integer, cc.Render>
M.by_buf = {}

--- Folds found with a wrong level in a window and fixed, newest last, to find out
--- what leaves them stale
---@type {row: integer, line: string, time: string}[]
M.fold_repairs = {}

M.icons = {
  header_user = '▌\u{F0B7B} ',
  header_assistant = '\u{EE0D} ',
  run = '\u{F489} ',
  read = '\u{F06E} ',
  edit = '\u{F448} ',
  write = '\u{F05F} ',
  plan = '\u{F0756} ',
  search = '\u{F422} ',
  web = '\u{F059F} ',
  tool = '\u{F425} ',
  task = '\u{F52E} ',
  skill = '\u{F0431} ',
  reasoning = '\u{F09D1} ',
  border = '▌',
}

-- Five backticks, tool output often holds three
local FENCE = '`````'

---@class cc.Block
---@field mark integer Range in ns_block from the title row to the tail blank row
---@field name string
---@field started number Seconds, for the duration on the title
---@field title string Title line without duration
---@field fence? integer Mark on the closing fence that bash output goes before
---@field children integer Subagent tool lines added so far
---@field bars integer[] Bar marks in ns_deco
---@field fold? integer Mark in ns over the whole block, with fold_tools
---@field error? boolean The tool returned an error
---@field status? [string, string][] Task state after the title, also in its fold text
---@field status_mark? integer Mark in ns_status, the fold text replaces it when closed

---@class cc.RenderOpts
---@field max_lines integer Hard cap on lines kept from one tool output
---@field fold_tools boolean Fold the whole body of tool calls and reasoning
---@field fold_threshold integer Without fold_tools, output lines shown before the rest is folded
---@field code_fold_lines integer Code blocks in answers longer than this start closed
---@field width fun(): integer Text width of the panel, when no window shows the buffer

---@class cc.Render
---@field buf integer
---@field opts cc.RenderOpts
---@field blocks table<string, cc.Block> Keyed by tool_use_id
---@field empty boolean Buffer still holds only its initial empty line
---@field turn_open boolean Assistant header written for the current turn
---@field text_open boolean A streamed text block is in progress
---@field streamed table<string, boolean> Message ids whose text arrived as stream events
---@field model? string Model of the message being streamed
---@field text_row? integer First row of the text block being streamed
---@field prompts string[] User prompts in order, for the input history
---@field prompt_marks integer[] Marks in ns_block on the first text row of each prompt
---@field folds_ok? table<string, true> Fold marks already seen at their level in every window
---@field fold_tries? table<string, integer> Repairs of each fold mark found stale
---@field tables table<integer, string[]> Original markdown of each table, by its ns_table mark
---@field table_width? integer Width the tables were last fitted to
---@field by_mark table<integer, cc.Block> Blocks by their ns_block mark, for foldtext
---@field tail? [string, string][][] Virtual lines kept after the last row
---@field tail_mark? integer
local R = {}
R.__index = R

---@param buf integer
---@param opts cc.RenderOpts
---@return cc.Render
function M.new(buf, opts)
  local self = setmetatable({
    buf = buf,
    opts = opts,
    blocks = {},
    empty = true,
    turn_open = false,
    text_open = false,
    streamed = {},
    prompts = {},
    prompt_marks = {},
    by_mark = {},
    tables = {},
  }, R)
  M.by_buf[buf] = self
  return self
end

---@param s string
---@return string[]
local function split(s)
  return vim.split(s, '\n', { plain = true })
end

---@param s string
---@return string
local function strip_ansi(s)
  return (s:gsub('\27%[[%d;]*m', ''))
end

---@param lines string[]
---@return string[]
local function trim_blank(lines)
  while #lines > 0 and lines[#lines] == '' do
    lines[#lines] = nil
  end
  while #lines > 0 and lines[1] == '' do
    table.remove(lines, 1)
  end
  return lines
end

---@param path? string
---@return string
local function lang_of(path)
  if type(path) ~= 'string' then
    return ''
  end
  return vim.filetype.match { filename = path } or ''
end

---@param path? string
---@return string
local function short_path(path)
  if type(path) ~= 'string' then
    return ''
  end
  return vim.fn.fnamemodify(path, ':~:.')
end

---@param ts? number
---@return string
local function format_time(ts)
  ts = ts or os.time()
  if os.date('%Y%m%d', ts) == os.date '%Y%m%d' then
    return os.date('%H:%M', ts) --[[@as string]]
  elseif os.date('%Y', ts) == os.date '%Y' then
    return os.date('%d %b %H:%M', ts) --[[@as string]]
  end
  return os.date('%d %b %Y %H:%M', ts) --[[@as string]]
end

---@param icon string
---@param label string
---@param value string
---@return string
local function action_line(icon, label, value)
  value = value:gsub('\n.*', ' …')
  return ('**%s %s** %s'):format(icon, label, value ~= '' and ('`' .. value .. '`') or '')
end

---@param lines string[]
---@param lang string
---@return string[]
local function code(lines, lang)
  local out = { '', FENCE .. lang }
  vim.list_extend(out, lines)
  out[#out + 1] = FENCE
  return out
end

---@param input table
---@return string[]
local function json_lines(input)
  local ok, json = pcall(vim.json.encode, input, { indent = '  ' })
  return split(ok and json or vim.inspect(input))
end

--- Title and body of a tool call, before its result
---@param name string
---@param input table
---@return string title
---@return string[] body
local function tool_layout(name, input)
  local I = M.icons
  if name == 'Bash' then
    local cmd = split(input.command or '')
    cmd[1] = '> ' .. cmd[1]
    cmd[#cmd + 1] = ''
    return action_line(I.run, 'run', input.description or input.command or ''), code(cmd, 'bash')
  elseif name == 'Read' then
    return action_line(I.read, 'read', short_path(input.file_path)), {}
  elseif name == 'Write' then
    return action_line(I.write, 'write', short_path(input.file_path)),
      code(split(input.content or ''), lang_of(input.file_path))
  elseif name == 'Edit' or name == 'MultiEdit' then
    return action_line(I.edit, 'edit', short_path(input.file_path)), {}
  elseif name == 'TodoWrite' then
    local lines = {}
    for _, t in ipairs(input.todos or {}) do
      local box = t.status == 'completed' and '[x]' or t.status == 'in_progress' and '[-]' or '[ ]'
      lines[#lines + 1] = ('- %s %s '):format(box, t.content)
    end
    return action_line(I.plan, 'plan', ('%d todos'):format(#lines)), lines
  elseif name == 'Glob' then
    return action_line(I.search, 'glob', input.pattern or ''), {}
  elseif name == 'Grep' then
    local where = input.path or input.glob
    return action_line(I.search, 'grep', (where and (short_path(where) .. ' ') or '') .. (input.pattern or '')), {}
  elseif name == 'WebFetch' then
    return action_line(I.web, 'fetch', input.url or ''), {}
  elseif name == 'WebSearch' then
    return action_line(I.web, 'search', input.query or ''), {}
  elseif name == 'Task' or name == 'Agent' then
    local value = input.description or ''
    if input.subagent_type then
      value = ('%s (@%s)'):format(value, input.subagent_type)
    end
    return action_line(I.task, 'task', value), {}
  elseif name == 'Skill' then
    return action_line(I.skill, 'skill', input.skill or input.command or ''), {}
  end
  local server, tool = name:match '^mcp__(.-)__(.+)$'
  if server then
    local shown = input.thought or input.content or input.text or input.query or input.url or input.input
    local body = { '' }
    vim.list_extend(body, type(shown) == 'string' and split(shown) or json_lines(input))
    -- Not bold, so render-markdown keeps the dim line highlight
    return ('%s %s: %s'):format(I.tool, server, tool), body
  end
  local body = { '', '**Input**' }
  vim.list_extend(body, code(json_lines(input), 'json'))
  return action_line(I.tool, 'tool', name), body
end

---@param s string
---@param old string
---@param new string
---@param all? boolean
---@return string? # nil when `old` is not in `s`
local function replace(s, old, new, all)
  if old == '' or not s:find(old, 1, true) then
    return nil
  end
  local out, i = {}, 1
  while true do
    local a, b = s:find(old, i, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(i, a - 1) .. new
    i = b + 1
    if not all then
      break
    end
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

---@class cc.DiffLine
---@field text string
---@field num? integer
---@field sign? '+'|'-'|' '

--- Hunks of old -> new with their line numbers
---@param old string
---@param new string
---@return cc.DiffLine[]
local function diff_lines(old, new)
  local d = vim.diff(old .. '\n', new .. '\n', { ctxlen = 3 }) --[[@as string]]
  local out = {}
  local o, n = 0, 0
  local seen_hunk = false
  for _, l in ipairs(split(d)) do
    local a, c = l:match '^@@ %-(%d+),?%d* %+(%d+),?%d* @@'
    if a then
      o, n = tonumber(a), tonumber(c)
      -- opencode hides the first hunk header and prints later ones as is
      if seen_hunk then
        out[#out + 1] = { text = l }
      end
      seen_hunk = true
    elseif l ~= '' and not l:match '^\\ No newline' then
      local sign = l:sub(1, 1)
      if sign == '-' then
        out[#out + 1] = { text = l:sub(2), num = o, sign = '-' }
        o = o + 1
      elseif sign == '+' then
        out[#out + 1] = { text = l:sub(2), num = n, sign = '+' }
        n = n + 1
      else
        out[#out + 1] = { text = l:sub(2), num = n, sign = ' ' }
        o, n = o + 1, n + 1
      end
    end
  end
  -- The newline added for vim.diff shows up as an empty context line
  while #out > 0 and out[#out].sign == ' ' and out[#out].text == '' do
    out[#out] = nil
  end
  return out
end

--- Diff of an Edit or MultiEdit against the whole file, for context lines and file line
--- numbers. Before the edit runs the file holds the old text, in history the new one.
---@param input table
---@return cc.DiffLine[]
local function edit_diff(input)
  local edits = input.edits
    or { { old_string = input.old_string, new_string = input.new_string, replace_all = input.replace_all } }
  local text
  if type(input.file_path) == 'string' and vim.fn.filereadable(input.file_path) == 1 then
    text = table.concat(vim.fn.readfile(input.file_path, 'b'), '\n')
  end
  local before, after = text, text
  for _, e in ipairs(edits) do
    after = after and replace(after, e.old_string or '', e.new_string or '', e.replace_all)
  end
  if not after then
    before, after = text, text
    for i = #edits, 1, -1 do
      local e = edits[i]
      before = before and replace(before, e.new_string or '', e.old_string or '', e.replace_all)
    end
  end
  if before and after then
    return diff_lines(before, after)
  end
  local out = {}
  for i, e in ipairs(edits) do
    if i > 1 then
      out[#out + 1] = { text = '' }
    end
    vim.list_extend(out, diff_lines(e.old_string or '', e.new_string or ''))
  end
  return out
end

---@type table<integer, boolean>
local refresh_pending = {}

--- A window can keep a fold level computed before the fold mark existed, in a way
--- not reproduced yet. Compare every fold mark with the levels of each window.
---@param buf integer
local function check_folds(buf)
  local r = M.by_buf[buf]
  if not r then
    return
  end
  -- A fold seen at its level once is not checked again. A repair checks again after
  -- its own write, so give up on a fold it does not fix.
  r.folds_ok = r.folds_ok or {}
  r.fold_tries = r.fold_tries or {}
  local stale = {}
  for level, space in ipairs { ns_open, ns } do
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, space, 0, -1, { details = true })) do
      local key = space .. ':' .. m[1]
      if m[4].end_row > m[2] and not r.folds_ok[key] and (r.fold_tries[key] or 0) < 3 then
        local ok = true
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          if api.nvim_win_call(win, function()
            return vim.fn.foldlevel(m[2] + 1)
          end) < level then
            ok = false
            stale[m[2]] = true
          end
        end
        r.folds_ok[key] = ok or nil
        r.fold_tries[key] = not ok and (r.fold_tries[key] or 0) + 1 or nil
      end
    end
  end
  for row in pairs(stale) do
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    M.fold_repairs[#M.fold_repairs + 1] = { row = row, line = line:sub(1, 80), time = os.date '%H:%M:%S' }
    r:_touch(row)
  end
end

--- render-markdown redraws on TextChanged, which only fires for the current buffer.
--- The output is written while the input has focus, so ask it to redraw.
---@param buf integer
local function refresh_markdown(buf)
  if refresh_pending[buf] then
    return
  end
  refresh_pending[buf] = true
  vim.defer_fn(function()
    refresh_pending[buf] = nil
    if not api.nvim_buf_is_valid(buf) or #vim.fn.win_findbuf(buf) == 0 then
      return
    end
    check_folds(buf)
    local ok, rm = pcall(require, 'render-markdown')
    if ok and rm.render then
      pcall(rm.render, { buf = buf, event = 'TextChanged' })
    end
  end, 50)
end

---@type (fun())[]
local in_normal_stack = {}

--- Run `fn` in normal mode state.
--- NOTE: Neovim skips fold updates in every window while in insert mode, which is
--- whenever the input is being typed in. Writes made from :normal update them.
---@param fn fun()
local function in_normal(fn)
  if not api.nvim_get_mode().mode:match '^[iR]' then
    return fn()
  end
  local ok, err
  in_normal_stack[#in_normal_stack + 1] = function()
    ok, err = pcall(fn)
  end
  vim.cmd(('noautocmd normal! %slua require(%q)._run_in_normal()\r'):format(vim.keycode '<Cmd>', root .. 'render'))
  in_normal_stack[#in_normal_stack] = nil
  if ok == nil then
    error 'yacc: :normal did not run the write'
  elseif not ok then
    error(err, 0)
  end
end

function M._run_in_normal()
  in_normal_stack[#in_normal_stack]()
end

--- Run `fn` with the buffer writable. Windows that showed the end of the buffer keep
--- following it.
---@param fn fun(buf: integer)
function R:_modify(fn)
  local buf = self.buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local follow = self:_followers()
  -- NOTE: with conceal_lines on, the markdown highlighter runs its injection query on
  -- the whole buffer at each write (140 ms at 45k lines). It only hides fence lines,
  -- which render-markdown draws anyway, and it can turn itself back on, so clear it here.
  local hl = vim.treesitter.highlighter.active[buf]
  if hl then
    hl._conceal_line = false
  end
  vim.bo[buf].modifiable = true
  local ok, err = pcall(in_normal, function()
    fn(buf)
  end)
  vim.bo[buf].modifiable = false
  if not ok then
    error(err, 0)
  end
  self.empty = false
  self:_place_tail()
  for _, win in ipairs(follow) do
    self:_scroll_end(win)
  end
  refresh_markdown(buf)
end

--- Windows that show the end of the buffer, to keep at the end after a write
---@return integer[]
function R:_followers()
  local last = api.nvim_buf_line_count(self.buf)
  local follow = {}
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    -- 'w$' only updates on redraw, the cursor check covers several writes in one tick
    if vim.fn.line('w$', win) >= last or api.nvim_win_get_cursor(win)[1] >= last then
      follow[#follow + 1] = win
    end
  end
  return follow
end

---@param win integer
---@param bottom? boolean Put the last row at the bottom of the window
function R:_scroll_end(win, bottom)
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(self.buf), 0 })
  -- The cursor line alone does not bring the virtual lines below it into view
  if self.tail or bottom then
    api.nvim_win_call(win, function()
      vim.cmd 'normal! zb'
    end)
  end
end

--- Virtual lines after the last row, such as the queued prompts. Nil removes them.
---@param lines? [string, string][][]
function R:set_tail(lines)
  -- Called on every refresh, scroll only when it changes
  if not api.nvim_buf_is_valid(self.buf) or vim.deep_equal(lines, self.tail) then
    return
  end
  local follow = self:_followers()
  self.tail = lines
  self:_place_tail()
  -- Without the tail, the rows it took would stay empty below the end
  for _, win in ipairs(follow) do
    self:_scroll_end(win, true)
  end
end

--- Writes after the last row leave the mark above them, move it back to the end
function R:_place_tail()
  if not self.tail then
    if self.tail_mark then
      api.nvim_buf_del_extmark(self.buf, ns_tail, self.tail_mark)
      self.tail_mark = nil
    end
    return
  end
  self.tail_mark = api.nvim_buf_set_extmark(self.buf, ns_tail, api.nvim_buf_line_count(self.buf) - 1, 0, {
    id = self.tail_mark,
    virt_lines = self.tail,
    virt_lines_leftcol = true,
  })
end

--- Render `fn` into a bare scratch buffer, then copy it in one write, so a long
--- transcript pays the output buffer's per-write highlighter cost once
---@param fn fun()
function R:batch(fn)
  if not self.empty then
    return fn()
  end
  local real = self.buf
  self.buf = api.nvim_create_buf(false, true)
  local ok, err = pcall(fn)
  local tmp = self.buf
  self.buf = real
  local lines = api.nvim_buf_get_lines(tmp, 0, -1, false)
  self:_modify(function(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end)
  -- Same ids, so the blocks keep pointing at their marks
  for _, m in ipairs(api.nvim_buf_get_extmarks(tmp, -1, 0, -1, { details = true })) do
    local d = m[4]
    local nsid = d.ns_id
    d.ns_id = nil
    d.invalid = nil
    -- Reported for virt_text_win_col, but not accepted back
    if d.virt_text_pos == 'win_col' then
      d.virt_text_pos = nil
    end
    d.id = m[1]
    api.nvim_buf_set_extmark(real, nsid, m[2], m[3], d)
  end
  api.nvim_buf_delete(tmp, { force = true })
  for _, space in ipairs { ns, ns_open } do
    for _, m in ipairs(api.nvim_buf_get_extmarks(real, space, 0, -1, {})) do
      self:_touch(m[2])
    end
  end
  if not ok then
    error(err)
  end
end

--- Fold levels come from foldexpr, which Neovim evaluates when lines change. A fold mark
--- added after its lines leaves them stale: rewrite the first one with the same text,
--- and the evaluation runs on from there while levels change.
---@param row integer
function R:_touch(row)
  local line = api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1]
  if not line or #vim.fn.win_findbuf(self.buf) == 0 then
    return
  end
  self:_modify(function(buf)
    if line == '' then
      api.nvim_buf_set_text(buf, row, 0, row, 0, { ' ' })
      api.nvim_buf_set_text(buf, row, 0, row, 1, { '' })
    else
      api.nvim_buf_set_text(buf, row, 0, row, #line, { line })
    end
  end)
end

--- Set the open state of a new fold. Once a fold was opened or closed by hand, Neovim
--- gives new folds the state of their neighbours instead of applying 'foldlevel'.
---@param row integer
---@param closed boolean
function R:_fold_state(row, closed)
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    api.nvim_win_call(win, function()
      -- Each :foldclose closes one more level, so only act when the state differs
      local is_closed = vim.fn.foldclosed(row + 1) ~= -1
      if vim.fn.foldlevel(row + 1) > 0 and is_closed ~= closed then
        vim.cmd(('silent! %dfold%s'):format(row + 1, closed and 'close' or 'open'))
      end
    end)
  end
end

---@return string
function R:_last_line()
  return api.nvim_buf_get_lines(self.buf, -2, -1, false)[1] or ''
end

--- Append lines at the end of the buffer
---@param lines string[]
---@return integer row Row of the first line
function R:_append(lines)
  local row
  self:_modify(function(buf)
    if self.empty then
      row = 0
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    else
      row = api.nvim_buf_line_count(buf)
      api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    end
  end)
  return row
end

function R:_ensure_blank()
  if not self.empty and self:_last_line() ~= '' then
    self:_append { '' }
  end
end

---@param row integer
---@param opts vim.api.keyset.set_extmark
---@return integer
function R:_deco(row, opts)
  return api.nvim_buf_set_extmark(self.buf, ns_deco, row, 0, opts)
end

---@param row integer
---@param hl string
---@param win_col integer
---@return integer
function R:_bar(row, hl, win_col)
  return self:_deco(row, {
    virt_text = { { M.icons.border, hl } },
    virt_text_pos = 'overlay',
    virt_text_win_col = win_col,
    virt_text_repeat_linebreak = true,
  })
end

--- `----`, the role row and a spacer
---@param user boolean
---@param model? string
---@param ts? number
---@return integer row Row of the spacer
function R:_header(user, model, ts)
  self:_ensure_blank()
  local row = self:_append { '----', '', '' }
  local hl = user and 'CcMessageRoleUser' or 'CcMessageRoleAssistant'
  local virt = {
    { user and M.icons.header_user or M.icons.header_assistant, hl },
    { ' ' },
    { user and 'USER' or 'CLAUDE', hl },
  }
  if model then
    vim.list_extend(virt, { { ' ' }, { model, 'CcHint' } })
  end
  self:_deco(row + 1, { virt_text = virt, virt_text_win_col = -3, priority = 10 })
  self:_deco(row + 1, {
    virt_text = { { ' ' .. format_time(ts), 'CcHint' } },
    virt_text_pos = 'right_align',
    priority = 9,
  })
  return row + 2
end

---@param model? string
---@param ts? number
function R:_ensure_turn(model, ts)
  if not self.turn_open then
    self.turn_open = true
    self:_header(false, model or self.model, ts)
  end
end

---@param text string
---@param ts? number
function R:user(text, ts)
  self.turn_open = false
  text = vim.trim(text)
  self.prompts[#self.prompts + 1] = text
  local spacer = self:_header(true, nil, ts)
  local lines = split(text)
  lines[#lines + 1] = ''
  local row = self:_append(lines)
  for r = spacer, row + #lines - 2 do
    self:_bar(r, 'CcMessageRoleUser', -3)
  end
  self.prompt_marks[#self.prompt_marks + 1] = api.nvim_buf_set_extmark(self.buf, ns_block, row, 0, {})
end

--- Dim lines for local events, like a mode change
---@param lines string[]
function R:note(lines)
  self:_ensure_blank()
  local all = vim.list_slice(lines)
  all[#all + 1] = ''
  local row = self:_append(all)
  for r = row, row + #lines - 1 do
    self:_deco(r, { line_hl_group = 'CcHint' })
  end
end

---@param msg string
---@return string[]
local function callout(msg)
  local lines = split(vim.trim(msg))
  if #lines == 1 then
    return { '> [!ERROR] ' .. lines[1] }
  end
  local out = { '> [!ERROR]', '>' }
  for _, l in ipairs(lines) do
    out[#out + 1] = '> ' .. l
  end
  return out
end

---@param msg string
function R:error(msg)
  self:_ensure_blank()
  local lines = callout(msg)
  lines[#lines + 1] = ''
  self:_append(lines)
end

function R:compacted()
  self:_ensure_blank()
  local row =
    self:_append { '━━━━━━━━━━━━ Session compacted ━━━━━━━━━━━━', '' }
  self:_deco(row, { line_hl_group = 'CcBorder', priority = 5000 })
end

--- Fold each fenced code block of an answer, closed when longer than code_fold_lines
---@param first integer
---@param last integer
function R:_code_folds(first, last)
  local lines = api.nvim_buf_get_lines(self.buf, first, last + 1, false)
  local open_row, fence
  for i, l in ipairs(lines) do
    local row = first + i - 1
    if not open_row then
      local f = l:match '^%s*(```+)' or l:match '^%s*(~~~+)'
      if f then
        open_row, fence = row, f
      end
    elseif l:match('^%s*' .. fence:sub(1, 1):rep(#fence) .. '+%s*$') then
      -- Fences stay out: render-markdown draws the language header on the opening one
      local size = row - open_row - 1
      if size > 0 then
        local long = size > self.opts.code_fold_lines
        api.nvim_buf_set_extmark(self.buf, long and ns or ns_open, open_row + 1, 0, { end_row = row, end_col = 0 })
        self:_touch(open_row + 1)
        self:_fold_state(open_row + 1, long)
      end
      open_row = nil
    end
  end
end

--- Text width tables must fit in
---@return integer
function R:_width()
  local win = vim.fn.win_findbuf(self.buf)[1]
  if win then
    local info = vim.fn.getwininfo(win)[1]
    return info.width - info.textoff
  end
  return self.opts.width()
end

--- Track the tables of lines written at `row`
---@param row integer
---@param spans cc.TableSpan[]
function R:_track_tables(row, spans)
  for _, t in ipairs(spans) do
    local id = api.nvim_buf_set_extmark(self.buf, ns_table, row + t.first - 1, 0, {
      end_row = row + t.last,
      end_col = 0,
      right_gravity = false,
    })
    self.tables[id] = t.source
  end
end

--- Fit every table again to `width`, from the markdown the model wrote
---@param width integer
function R:reflow_tables(width)
  if width == self.table_width then
    return
  end
  self.table_width = width
  for id, source in pairs(self.tables) do
    local pos = api.nvim_buf_get_extmark_by_id(self.buf, ns_table, id, { details = true })
    if pos[1] then
      local first, stop = pos[1], pos[3].end_row
      local fitted = tables.reflow(source, width)
      if not vim.deep_equal(fitted, api.nvim_buf_get_lines(self.buf, first, stop, false)) then
        self:_modify(function(buf)
          api.nvim_buf_set_lines(buf, first, stop, false, fitted)
        end)
        api.nvim_buf_set_extmark(self.buf, ns_table, first, 0, {
          id = id,
          end_row = first + #fitted,
          end_col = 0,
          right_gravity = false,
        })
      end
    end
  end
end

---@param text string
function R:_text(text)
  self.table_width = self:_width()
  local lines, spans = tables.reflow(trim_blank(split(text)), self.table_width)
  if #lines == 0 then
    return
  end
  self:_ensure_blank()
  lines[#lines + 1] = ''
  local row = self:_append(lines)
  self:_track_tables(row, spans)
  self:_code_folds(row, row + #lines - 2)
end

--- Fold body rows after the first `fold_threshold`, from `first` to `last` included
---@param first integer
---@param last integer
function R:_fold_tail(first, last)
  if self.opts.fold_tools then
    return
  end
  local from = first + self.opts.fold_threshold
  if from > last then
    return
  end
  api.nvim_buf_set_extmark(self.buf, ns, from, 0, { end_row = last + 1, end_col = 0 })
  self:_touch(from)
  self:_fold_state(from, true)
end

--- Fold from `first` up to the row before `tail`. Lines inserted at `tail` join it, so a
--- body that starts empty grows into the fold.
---@param first integer
---@param tail integer
---@return integer
function R:_fold_body(first, tail)
  local id = api.nvim_buf_set_extmark(self.buf, ns, first, 0, {
    end_row = tail,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  self:_touch(first)
  self:_fold_state(first, true)
  return id
end

---@param id string
---@return integer? title
---@return integer? tail
function R:_block_pos(id)
  local b = self.blocks[id]
  local pos = b and api.nvim_buf_get_extmark_by_id(self.buf, ns_block, b.mark, { details = true })
  if not pos or not pos[1] then
    return nil
  end
  return pos[1], pos[3].end_row
end

--- The tool bar covers the title down to the last body row, for blocks of 3 rows or more
---@param id string
function R:_bars(id)
  local b = self.blocks[id]
  local title, tail = self:_block_pos(id)
  if not title then
    return
  end
  for _, m in ipairs(b.bars) do
    api.nvim_buf_del_extmark(self.buf, ns_deco, m)
  end
  b.bars = {}
  if tail - title < 3 then
    return
  end
  for r = title, tail - 1 do
    b.bars[#b.bars + 1] = self:_bar(r, 'CcToolBorder', -1)
  end
end

--- Insert lines at a row inside a block, keeping its range and bars right
---@param id string
---@param row integer
---@param lines string[]
function R:_insert(id, row, lines)
  self:_modify(function(buf)
    api.nvim_buf_set_lines(buf, row, row, false, lines)
  end)
  self:_bars(id)
end

--- Diff body with opencode's gutter: line number and sign drawn over the indent
---@param id string
---@param dl cc.DiffLine[]
---@param lang string
function R:_diff(id, dl, lang)
  local width = 1
  for _, l in ipairs(dl) do
    if l.num then
      width = math.max(width, #tostring(l.num))
    end
  end
  local pad = (' '):rep(width + 2)
  local lines = { '', FENCE .. lang }
  for _, l in ipairs(dl) do
    lines[#lines + 1] = l.num and (pad .. l.text) or l.text
  end
  lines[#lines + 1] = FENCE
  local _, tail = self:_block_pos(id)
  self:_insert(id, tail, lines)
  for i, l in ipairs(dl) do
    if l.num then
      local r = tail + 1 + i
      local hl = l.sign == '+' and 'CcDiffAddGutter' or l.sign == '-' and 'CcDiffDeleteGutter' or 'CcDiffGutter'
      local opts = {
        virt_text = { { ('%' .. width .. 'd'):format(l.num), hl }, { l.sign, hl }, { ' ', hl } },
        virt_text_pos = 'overlay',
        priority = 5000,
      }
      if l.sign ~= ' ' then
        opts.end_row = r + 1
        opts.end_col = 0
        opts.hl_group = l.sign == '+' and 'CcDiffAdd' or 'CcDiffDelete'
        opts.hl_eol = true
      end
      self:_deco(r, opts)
    end
  end
end

---@param c table tool_use content block
---@param ts? number
function R:_tool(c, ts)
  local input = c.input or {}
  local title, body = tool_layout(c.name, input)
  local lines = { title }
  vim.list_extend(lines, body)
  lines[#lines + 1] = ''
  self:_ensure_blank()
  local row = self:_append(lines)
  local tail = row + #lines - 1
  local b = {
    name = c.name,
    started = ts or vim.uv.now() / 1000,
    title = title,
    children = 0,
    bars = {},
    mark = api.nvim_buf_set_extmark(self.buf, ns_block, row, 0, {
      end_row = tail,
      end_col = 0,
      end_right_gravity = true,
    }),
  }
  self.blocks[c.id] = b
  self.by_mark[b.mark] = b
  -- The title is the fold text, so the whole block folds away
  if self.opts.fold_tools then
    b.fold = self:_fold_body(row, tail)
  end
  if c.name == 'Bash' then
    b.fence = api.nvim_buf_set_extmark(self.buf, ns_block, tail - 1, 0, {})
  elseif c.name:match '^mcp__' then
    self:_deco(row, { line_hl_group = 'CcHint', priority = 5000 })
  elseif c.name == 'Write' then
    -- Body: '', fence, content, fence
    self:_fold_tail(row + 3, tail - 2)
  elseif c.name == 'Edit' or c.name == 'MultiEdit' then
    self:_diff(c.id, edit_diff(input), lang_of(input.file_path))
  end
  self:_bars(c.id)
end

--- State of a running shell or subagent after its title. A closed fold hides end of
--- line text, so the fold text shows it too.
---@param id string tool_use_id
---@param chunks? [string, string][] Nil clears it
function R:set_status(id, chunks)
  local b = self.blocks[id]
  local row = b and self:_block_pos(id)
  if not row then
    return
  end
  b.status = chunks
  if chunks then
    local text = { { ' ' } }
    vim.list_extend(text, chunks)
    b.status_mark = api.nvim_buf_set_extmark(self.buf, ns_status, row, 0, {
      id = b.status_mark,
      virt_text = text,
      virt_text_pos = 'eol',
    })
  elseif b.status_mark then
    api.nvim_buf_del_extmark(self.buf, ns_status, b.status_mark)
    b.status_mark = nil
  end
end

--- A tool call made by a subagent, listed under its Task block
---@param parent string tool_use_id of the Task
---@param msg table assistant message
function R:subagent(parent, msg)
  local b = self.blocks[parent]
  if not b then
    return
  end
  for _, c in ipairs(msg.content or {}) do
    if c.type == 'tool_use' then
      local title = tool_layout(c.name, c.input or {})
      local _, tail = self:_block_pos(parent)
      local lines = { ' ' .. title }
      if b.children == 0 then
        table.insert(lines, 1, '')
      end
      b.children = b.children + 1
      self:_insert(parent, tail, lines)
    end
  end
end

---@param content string|table
---@return string[]
local function result_lines(content)
  if type(content) == 'string' then
    return split(strip_ansi(content))
  end
  local lines = {}
  for _, c in ipairs(content or {}) do
    if c.type == 'text' then
      vim.list_extend(lines, split(strip_ansi(c.text)))
    else
      lines[#lines + 1] = ('[%s]'):format(c.type)
    end
  end
  return lines
end

---@param lines string[]
---@param max integer
---@return string[]
local function cap(lines, max)
  if #lines <= max then
    return lines
  end
  local out = vim.list_slice(lines, 1, max)
  out[#out + 1] = ('… %d more lines'):format(#lines - max)
  return out
end

--- Count line for glob and grep, from the result text
---@param name string
---@param out string[]
---@return string
local function search_summary(name, out)
  if out[1] and out[1]:match '^Found ' then
    return (out[1]:gsub('(%d+)', '`%1`', 1))
  elseif out[1] and out[1]:match '^No ' then
    return out[1]
  end
  local n = #out
  if name == 'Glob' then
    return ('Found `%d` file(s)'):format(n)
  end
  return ('Found `%d` %s'):format(n, n == 1 and 'match' or 'matches')
end

-- Tools whose result opencode does not show
local quiet =
  { Read = true, Write = true, Edit = true, MultiEdit = true, TodoWrite = true, WebFetch = true, Skill = true }

---@param res table tool_result content block
---@param ts? number
function R:tool_result(res, ts)
  local id = res.tool_use_id
  local b = self.blocks[id]
  local title, tail = self:_block_pos(id)
  if not b or not title then
    return
  end
  local out = trim_blank(cap(result_lines(res.content), self.opts.max_lines))
  local name = b.name

  local secs = (ts or vim.uv.now() / 1000) - b.started
  if secs >= 1 then
    local old = api.nvim_buf_get_lines(self.buf, title, title + 1, false)[1]
    self:_modify(function(buf)
      api.nvim_buf_set_text(buf, title, 0, title, #old, { ('%s %ds'):format(b.title, math.floor(secs)) })
    end)
  end

  if res.is_error then
    local lines = { '' }
    vim.list_extend(lines, callout(table.concat(cap(out, 10), '\n')))
    self:_insert(id, tail, lines)
    b.error = true
  elseif name == 'Bash' then
    local fence = api.nvim_buf_get_extmark_by_id(self.buf, ns_block, b.fence, {})[1]
    if #out > 0 then
      self:_insert(id, fence, out)
      self:_fold_tail(fence, fence + #out)
    end
  elseif name == 'Glob' or name == 'Grep' then
    self:_insert(id, tail, { search_summary(name, out) })
  elseif name == 'WebSearch' or name == 'Task' or name == 'Agent' then
    local lines = { '' }
    vim.list_extend(lines, out)
    self:_insert(id, tail, lines)
    self:_fold_tail(tail + 1, tail + #out)
  elseif not quiet[name] then
    local lines = { '', '**Result**', '' }
    vim.list_extend(lines, out)
    self:_insert(id, tail, lines)
    self:_fold_tail(tail + 3, tail + 2 + #out)
  end
end

--- Partial assistant output from `--include-partial-messages`
---@param ev table
function R:stream_event(ev)
  if ev.type == 'message_start' then
    self.streamed[ev.message.id] = true
    self.model = ev.message.model
  elseif ev.type == 'content_block_start' and ev.content_block.type == 'text' then
    self:_ensure_turn()
    self:_ensure_blank()
    self.text_row = self:_append { '' }
    self.text_open = true
  elseif ev.type == 'content_block_delta' and ev.delta.type == 'text_delta' and self.text_open then
    local parts = split(ev.delta.text)
    self:_modify(function(buf)
      local n = api.nvim_buf_line_count(buf)
      local last = self:_last_line()
      api.nvim_buf_set_text(buf, n - 1, #last, n - 1, #last, parts)
    end)
  elseif ev.type == 'content_block_stop' and self.text_open then
    self.text_open = false
    local last = api.nvim_buf_line_count(self.buf)
    local lines = api.nvim_buf_get_lines(self.buf, self.text_row, last, false)
    self.table_width = self:_width()
    local fitted, spans = tables.reflow(lines, self.table_width)
    if not vim.deep_equal(lines, fitted) then
      self:_modify(function(buf)
        api.nvim_buf_set_lines(buf, self.text_row, last, false, fitted)
      end)
    end
    self:_track_tables(self.text_row, spans)
    self:_code_folds(self.text_row, api.nvim_buf_line_count(self.buf) - 1)
    self:_ensure_blank()
  end
end

---@param text string
function R:_reasoning(text)
  local body = trim_blank(split(text))
  local lines = { ('**%s Reasoning** '):format(M.icons.reasoning), '' }
  vim.list_extend(lines, body)
  lines[#lines + 1] = ''
  self:_ensure_blank()
  local row = self:_append(lines)
  for r = row, row + #lines - 2 do
    self:_deco(r, { line_hl_group = 'CcReasoningText' })
    self:_bar(r, 'CcToolBorder', -1)
  end
  if self.opts.fold_tools then
    self:_fold_body(row, row + #lines - 1)
  end
  self:_fold_tail(row + 2, row + #lines - 2)
end

---@param msg table Anthropic message with role "assistant"
---@param ts? number
function R:assistant(msg, ts)
  local streamed = self.streamed[msg.id]
  for _, c in ipairs(msg.content or {}) do
    if c.type == 'text' and not streamed and c.text ~= '' then
      self:_ensure_turn(msg.model, ts)
      self:_text(c.text)
    elseif c.type == 'thinking' and c.thinking ~= '' then
      self:_ensure_turn(msg.model, ts)
      self:_reasoning(c.thinking)
    elseif c.type == 'tool_use' or c.type == 'server_tool_use' then
      self:_ensure_turn(msg.model, ts)
      self:_tool(c, ts)
    end
  end
end

--- In a live stream, our own prompts are already rendered and other user text is
--- injected by the CLI, such as a skill body. Only history shows user text.
---@param msg table Anthropic message with role "user"
---@param live boolean
---@param ts? number
function R:user_message(msg, live, ts)
  local content = msg.content
  if type(content) == 'string' then
    content = { { type = 'text', text = content } }
  end
  local texts = {}
  for _, c in ipairs(content or {}) do
    if c.type == 'tool_result' then
      self:tool_result(c, ts)
    elseif c.type == 'text' then
      texts[#texts + 1] = c.text
    end
  end
  local text = table.concat(texts, '\n')
  -- A live interrupt is noted by the session when the turn ends
  if text:match '^%[Request interrupted' then
    if not live then
      self:note { 'Interrupted' }
    end
  elseif text ~= '' and not live then
    self:user(text, ts)
  end
end

function R:turn_end()
  self.text_open = false
end

function M.foldexpr()
  local row = vim.v.lnum - 1
  for level, space in ipairs { ns_open, ns } do
    local marks = api.nvim_buf_get_extmarks(0, space, { row, 0 }, { row, -1 }, { overlap = true, details = true })
    for _, m in ipairs(marks) do
      local end_row = m[4].end_row
      -- An empty body fold starts and ends on the tail row
      if end_row > m[2] then
        if m[2] == row then
          return '>' .. level
        elseif m[2] < row and row < end_row then
          return tostring(level)
        end
      end
    end
  end
  return '0'
end

--- A tool title line as highlighted chunks: `**icon label** `value` 3s`
---@param line string
---@return [string, string][]
local function title_chunks(line)
  local head, rest = line:match '^%*%*(.-)%*%*%s*(.*)$'
  if not head then
    return { { line, 'CcHint' } }
  end
  local chunks = { { head, 'CcToolTitle' } }
  local value, after = rest:match '^`(.-)`%s*(.*)$'
  if value then
    chunks[#chunks + 1] = { ' ' .. value, 'CcToolValue' }
    rest = after
  end
  if rest ~= '' then
    chunks[#chunks + 1] = { ' ' .. rest, 'CcHint' }
  end
  return chunks
end

function M.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  local first = api.nvim_buf_get_lines(0, vim.v.foldstart - 1, vim.v.foldstart, false)[1] or ''
  local r = M.by_buf[api.nvim_get_current_buf()]
  local row = vim.v.foldstart - 1
  for _, m in ipairs(r and api.nvim_buf_get_extmarks(0, ns_block, { row, 0 }, { row, -1 }, {}) or {}) do
    local b = r.by_mark[m[1]]
    if b then
      local chunks = title_chunks(first)
      if b.error then
        chunks[#chunks + 1] = { ' ✗', 'DiagnosticError' }
      end
      for i, c in ipairs(b.status or {}) do
        chunks[#chunks + 1] = { (i == 1 and ' ' or '') .. c[1], c[2] }
      end
      if count > 1 then
        chunks[#chunks + 1] = { (' (%d lines)'):format(count - 1), 'NonText' }
      end
      return chunks
    end
  end
  if first:match('^%*%*' .. M.icons.reasoning) then
    local chunks = title_chunks(first)
    chunks[#chunks + 1] = { (' (%d lines)'):format(count - 1), 'NonText' }
    return chunks
  end
  local lang = first:match '^%s*```+%s*([%w_+-]+)' or first:match '^%s*~~~+%s*([%w_+-]+)'
  local what = lang and ('%s · %d lines'):format(lang, count) or ('%d lines'):format(count)
  local text = ('▶ %s hidden (zo open, zc close) ◀'):format(what)
  local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
  local room = info.width - info.textoff - vim.fn.strdisplaywidth(text)
  local pad = math.max(0, math.floor(room / 2))
  return ('-'):rep(pad) .. text .. ('-'):rep(math.max(0, room - pad))
end

M.foldexpr_expr = ("v:lua.require'%srender'.foldexpr()"):format(root)
M.foldtext_expr = ("v:lua.require'%srender'.foldtext()"):format(root)

return M
