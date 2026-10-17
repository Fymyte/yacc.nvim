--- Fit markdown tables to a width. render-markdown draws a table as wide as its longest
--- cells, and Neovim cannot wrap it, so wide tables get their cells wrapped here.
---
--- A wrapped cell continues on extra rows with the other cells empty, and a blank row
--- separates the rows of the original table. Header cells are cut with '…', because a
--- table can only have one header row.

local M = {}

-- Narrowest a column gets, unless its content is shorter
local MIN_COL = 8

-- Neovim wraps on the raw text, concealed markup included, while render-markdown pads
-- columns to the concealed width: a row with more markup than its column neighbours can
-- still spill over by a few cells
local SLACK = 2

--- Width of the raw text. Concealed markup still counts, because Neovim wraps on it.
---@param s string
---@return integer
local function visible(s)
  return vim.fn.strdisplaywidth(s)
end

--- Cells of a table row. Pipes inside code spans or escaped with '\' are kept.
---@param line string
---@return string[]
local function cells(line)
  local out, cur, code = {}, {}, false
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' and line:sub(i + 1, i + 1) == '|' then
      cur[#cur + 1] = '\\|'
      i = i + 2
    else
      if c == '`' then
        code = not code
      end
      if c == '|' and not code then
        out[#out + 1] = table.concat(cur)
        cur = {}
      else
        cur[#cur + 1] = c
      end
      i = i + 1
    end
  end
  out[#out + 1] = table.concat(cur)
  if vim.trim(out[1]) == '' then
    table.remove(out, 1)
  end
  if #out > 0 and vim.trim(out[#out]) == '' then
    table.remove(out)
  end
  return vim.tbl_map(vim.trim, out)
end

---@param row string[]
---@return boolean
local function is_delimiter(row)
  if #row == 0 then
    return false
  end
  for _, c in ipairs(row) do
    if not c:match '^:?%-+:?$' then
      return false
    end
  end
  return true
end

---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local lines, cur, cur_w = {}, '', 0
  for word in text:gmatch '%S+' do
    local w = visible(word)
    if cur_w > 0 and cur_w + 1 + w > width then
      lines[#lines + 1] = cur
      cur, cur_w = word, w
    elseif cur_w > 0 then
      cur, cur_w = cur .. ' ' .. word, cur_w + 1 + w
    else
      cur, cur_w = word, w
    end
  end
  lines[#lines + 1] = cur
  return lines
end

---@param text string
---@param width integer
---@return string
local function cut(text, width)
  if visible(text) <= width then
    return text
  end
  local n = vim.fn.strchars(text)
  while n > 0 and visible(vim.fn.strcharpart(text, 0, n)) > width - 1 do
    n = n - 1
  end
  return vim.fn.strcharpart(text, 0, n) .. '…'
end

--- Column widths that fit `avail`: narrow columns keep their width, wide ones share
--- the rest equally
---@param natural integer[]
---@param avail integer
---@return integer[]
local function widths(natural, avail)
  local order = {}
  for i = 1, #natural do
    order[i] = i
  end
  table.sort(order, function(a, b)
    return natural[a] < natural[b]
  end)
  local out, left = {}, #natural
  for _, i in ipairs(order) do
    local share = math.floor(avail / left)
    out[i] = math.max(math.min(natural[i], share), math.min(natural[i], MIN_COL))
    avail = avail - out[i]
    left = left - 1
  end
  return out
end

---@param row string[]
---@param n integer
---@return string
local function join(row, n)
  local parts = {}
  for i = 1, n do
    parts[i] = row[i] or ''
  end
  return '| ' .. table.concat(parts, ' | ') .. ' |'
end

--- One table, `rows[2]` is the delimiter
---@param rows string[][]
---@param width integer
---@return string[]? # nil when it already fits
local function fit(rows, width)
  local n = #rows[2]
  local natural = {}
  for i = 1, n do
    natural[i] = 1
    for r, row in ipairs(rows) do
      if r ~= 2 and row[i] then
        natural[i] = math.max(natural[i], visible(row[i]))
      end
    end
  end
  -- render-markdown draws each cell as '│ ' .. text .. ' ', plus the last border
  local chrome = 3 * n + 1
  local total = chrome
  for _, w in ipairs(natural) do
    total = total + w
  end
  if total <= width then
    return nil
  end
  local w = widths(natural, width - chrome - SLACK)

  local header = {}
  for i = 1, n do
    header[i] = cut(rows[1][i] or '', w[i])
  end
  local delimiter = {}
  for i, d in ipairs(rows[2]) do
    delimiter[i] = (d:sub(1, 1) == ':' and ':' or '') .. '---' .. (d:sub(-1) == ':' and ':' or '')
  end
  local out = { join(header, n), join(delimiter, n) }

  local wrapped, tall = {}, false
  for r = 3, #rows do
    local parts, height = {}, 1
    for i = 1, n do
      parts[i] = wrap(rows[r][i] or '', w[i])
      height = math.max(height, #parts[i])
    end
    tall = tall or height > 1
    wrapped[#wrapped + 1] = { parts = parts, height = height }
  end
  for k, row in ipairs(wrapped) do
    if tall and k > 1 then
      -- An all-empty row ends the table for treesitter, a no-break space does not
      out[#out + 1] = join({ '\u{a0}' }, n)
    end
    for j = 1, row.height do
      local line = {}
      for i = 1, n do
        line[i] = row.parts[i][j] or ''
      end
      out[#out + 1] = join(line, n)
    end
  end
  return out
end

---@class cc.TableSpan
---@field first integer Index of its first line in the output lines
---@field last integer Index of its last line
---@field source string[] The table as the model wrote it, to fit it again later

--- Lines of markdown with every table wider than `width` fitted to it, and where each
--- table ended up
---@param lines string[]
---@param width integer
---@return string[]
---@return cc.TableSpan[]
function M.reflow(lines, width)
  local out, spans = {}, {}
  local i, fence = 1, nil
  while i <= #lines do
    local line = lines[i]
    local f = line:match '^%s*(```+)' or line:match '^%s*(~~~+)'
    if fence then
      if f and line:match('^%s*' .. fence:sub(1, 1):rep(#fence) .. '+%s*$') then
        fence = nil
      end
      out[#out + 1] = line
      i = i + 1
    elseif f then
      fence = f
      out[#out + 1] = line
      i = i + 1
    elseif
      line:find('|', 1, true)
      and lines[i + 1]
      and is_delimiter(cells(lines[i + 1]))
      and #cells(lines[i + 1]) == #cells(line)
    then
      local rows = { cells(line), cells(lines[i + 1]) }
      local j = i + 2
      while lines[j] and lines[j]:find('|', 1, true) and vim.trim(lines[j]) ~= '' do
        rows[#rows + 1] = cells(lines[j])
        j = j + 1
      end
      local source = vim.list_slice(lines, i, j - 1)
      local first = #out + 1
      vim.list_extend(out, fit(rows, width) or source)
      spans[#spans + 1] = { first = first, last = #out, source = source }
      i = j
    else
      out[#out + 1] = line
      i = i + 1
    end
  end
  return out, spans
end

return M
