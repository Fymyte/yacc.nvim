--- Prompt navigation and marks in the output buffer.
---
--- Marks are Vim's lowercase marks, so `'a`, `]'` and `:marks` keep working. This module
--- draws the letters at the right edge and saves them per session, anchored to a prompt
--- because line numbers change when a transcript is rendered again.

local api = vim.api
local root = (...):match '^(.*%.)'
local render = require(root .. 'render')

local M = {}

local ns = api.nvim_create_namespace 'yacc.marks'
local LETTERS = 'abcdefghijklmnopqrstuvwxyz'

---@param s yacc.Session
---@return string?
local function file(s)
  if not s.session_id then
    return nil
  end
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'yacc', 'marks', s.session_id .. '.json')
end

--- First text row of each user prompt, 0-based, in order
---@param s yacc.Session
---@return integer[]
function M.prompt_rows(s)
  local rows = {}
  for _, id in ipairs(s.render.prompt_marks) do
    local pos = api.nvim_buf_get_extmark_by_id(s.out, render.ns_block, id, {})
    if pos[1] then
      rows[#rows + 1] = pos[1]
    end
  end
  return rows
end

--- Lowercase marks set in the output buffer
---@param buf integer
---@return table<string, integer> # letter -> row, 0-based
local function letters(buf)
  local out = {}
  for c in LETTERS:gmatch '.' do
    local m = api.nvim_buf_get_mark(buf, c)
    if m[1] > 0 then
      out[c] = m[1] - 1
    end
  end
  return out
end

---@param s yacc.Session
function M.refresh(s)
  if not api.nvim_buf_is_valid(s.out) then
    return
  end
  api.nvim_buf_clear_namespace(s.out, ns, 0, -1)
  local by_row = {}
  for c, row in pairs(letters(s.out)) do
    by_row[row] = by_row[row] or {}
    table.insert(by_row[row], c)
  end
  for row, cs in pairs(by_row) do
    table.sort(cs)
    api.nvim_buf_set_extmark(s.out, ns, row, 0, {
      virt_text = { { "'" .. table.concat(cs), 'CcMark' } },
      virt_text_pos = 'right_align',
      priority = 20,
    })
  end
end

--- Write the marks of the session as (prompt number, offset from that prompt)
---@param s yacc.Session
---@param allow_empty? boolean Remove the file when no mark is left
function M.save(s, allow_empty)
  local path = file(s)
  if not path or not api.nvim_buf_is_valid(s.out) then
    return
  end
  local rows = M.prompt_rows(s)
  local data = {}
  for c, row in pairs(letters(s.out)) do
    local prompt, base = 0, 0
    for i, r in ipairs(rows) do
      if r <= row then
        prompt, base = i, r
      end
    end
    local text = api.nvim_buf_get_lines(s.out, row, row + 1, false)[1]
    data[c] = { prompt = prompt, offset = row - base, text = text }
  end
  if next(data) == nil then
    -- A rewritten buffer has no mark yet, only a deletion may drop the saved ones
    if allow_empty then
      os.remove(path)
    end
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

--- Put back the saved marks, after the transcript was rendered
---@param s yacc.Session
function M.restore(s)
  local path = file(s)
  if not path or vim.fn.filereadable(path) == 0 then
    return
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if not ok or type(data) ~= 'table' then
    return
  end
  local rows = M.prompt_rows(s)
  local last = api.nvim_buf_line_count(s.out)
  for c, a in pairs(data) do
    local base = a.prompt == 0 and 0 or rows[a.prompt]
    if base and LETTERS:find(c, 1, true) then
      local row = math.min(base + a.offset, last - 1)
      -- Live notes are not in the transcript, so the same text can sit a few rows
      -- away: take the nearest line with it inside the prompt's turn
      if a.text and a.text ~= '' then
        local stop = rows[a.prompt + 1] or last
        local best
        for i, l in ipairs(api.nvim_buf_get_lines(s.out, base, stop, false)) do
          local r = base + i - 1
          if l == a.text and (not best or math.abs(r - row) < math.abs(best - row)) then
            best = r
          end
        end
        row = best or row
      end
      api.nvim_buf_set_mark(s.out, c, row + 1, 0, {})
    end
  end
  M.refresh(s)
end

--- Move the cursor of the current window to a row, keeping the prompt header in view
---@param row integer 0-based
function M.goto_row(row)
  vim.cmd "normal! m'"
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  -- The rule and the role row sit 3 rows above the prompt text
  vim.fn.winrestview { topline = math.max(1, row - 2) }
end

--- Jump to the next or previous prompt, `count` times
---@param s yacc.Session
---@param dir -1|1
---@param count integer
---@param from? integer Row to start from, 0-based, the cursor row by default
---@return boolean moved
function M.jump(s, dir, count, from)
  local rows = M.prompt_rows(s)
  local cur = from or api.nvim_win_get_cursor(0)[1] - 1
  local target
  for _ = 1, count do
    local found
    if dir > 0 then
      for _, r in ipairs(rows) do
        if r > cur then
          found = r
          break
        end
      end
    else
      for i = #rows, 1, -1 do
        if rows[i] < cur then
          found = rows[i]
          break
        end
      end
    end
    if not found then
      break
    end
    target, cur = found, found
  end
  if target then
    M.goto_row(target)
  end
  return target ~= nil
end

---@param buf integer
---@return integer?
local function win_of(buf)
  return vim.fn.win_findbuf(buf)[1]
end

---@param s yacc.Session
---@param keys yacc.Keys
function M.attach(s, keys)
  for _, key in ipairs(keys.prompt_next) do
    vim.keymap.set('n', key, function()
      -- Past the last prompt comes the input, with the output back at its end
      local input = win_of(s.input)
      if not M.jump(s, 1, vim.v.count1) and input then
        api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(s.out), 0 })
        api.nvim_set_current_win(input)
      end
    end, { buffer = s.out, desc = 'Claude: next prompt, then the input' })
  end
  for _, key in ipairs(keys.prompt_prev) do
    vim.keymap.set('n', key, function()
      M.jump(s, -1, vim.v.count1)
    end, { buffer = s.out, desc = 'Claude: previous prompt' })
    -- From the input, the previous prompt is the last one of the output
    vim.keymap.set('n', key, function()
      local out = win_of(s.out)
      if out then
        local count = vim.v.count1
        api.nvim_set_current_win(out)
        M.jump(s, -1, count, api.nvim_buf_line_count(s.out))
      end
    end, { buffer = s.input, desc = 'Claude: last prompt of the output' })
  end
  if keys.mark then
    vim.keymap.set('n', keys.mark, function()
      local c = vim.fn.getcharstr()
      vim.cmd('normal! m' .. c)
      if LETTERS:find(c, 1, true) then
        M.refresh(s)
        M.save(s)
      end
    end, { buffer = s.out, desc = 'Claude: set mark' })
  end
  if keys.mark_delete then
    vim.keymap.set('n', keys.mark_delete, function()
      local c = vim.fn.getcharstr()
      if LETTERS:find(c, 1, true) then
        api.nvim_buf_del_mark(s.out, c)
        M.refresh(s)
        M.save(s, true)
      end
    end, { buffer = s.out, desc = 'Claude: delete mark' })
  end
  -- Marks belong to the output buffer, also jump to them from the input
  for _, key in ipairs { "'", '`' } do
    vim.keymap.set('n', key, function()
      local c = vim.fn.getcharstr()
      local win = vim.fn.win_findbuf(s.out)[1]
      if
        LETTERS:find(c, 1, true)
        and win
        and api.nvim_buf_get_mark(s.input, c)[1] == 0
        and api.nvim_buf_get_mark(s.out, c)[1] > 0
      then
        api.nvim_set_current_win(win)
      end
      vim.cmd('normal! ' .. key .. c)
    end, { buffer = s.input, desc = 'Claude: jump to a mark of the output' })
  end

  -- :delmarks and friends have no event, catch up when the cursor rests
  api.nvim_create_autocmd('CursorHold', {
    buffer = s.out,
    callback = function()
      M.refresh(s)
    end,
  })
end

return M
