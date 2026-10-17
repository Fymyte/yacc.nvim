--- Images from the system clipboard, as base64 image blocks for a message

local M = {}

-- What the API takes as an image block
local SUPPORTED = { ['image/png'] = true, ['image/jpeg'] = true, ['image/gif'] = true, ['image/webp'] = true }

-- The API refuses images over 5 MB once encoded, base64 adds a third
local MAX_BYTES = math.floor(5 * 1024 * 1024 * 3 / 4)

---@param cmd string[]
---@return string?
local function run(cmd)
  if vim.fn.executable(cmd[1]) == 0 then
    return nil
  end
  local res = vim.system(cmd, { text = false }):wait()
  if res.code ~= 0 or not res.stdout or res.stdout == '' then
    return nil
  end
  return res.stdout
end

--- Commands to list the clipboard types and to read one type
---@return (fun(): string?)? list
---@return (fun(type: string): string?)? read
local function backend()
  if vim.env.WAYLAND_DISPLAY and vim.fn.executable 'wl-paste' == 1 then
    return function()
      return run { 'wl-paste', '--list-types' }
    end, function(type)
      return run { 'wl-paste', '--no-newline', '--type', type }
    end
  elseif vim.env.DISPLAY and vim.fn.executable 'xclip' == 1 then
    return function()
      return run { 'xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o' }
    end, function(type)
      return run { 'xclip', '-selection', 'clipboard', '-t', type, '-o' }
    end
  end
end

--- Re-encode an image as PNG, smaller than the API limit, with ImageMagick
---@param data string
---@return string?
local function shrink(data)
  local cmd = vim.fn.executable 'magick' == 1 and 'magick' or 'convert'
  if vim.fn.executable(cmd) == 0 then
    return nil
  end
  local res = vim.system({ cmd, '-', '-resize', '1568x1568>', 'png:-' }, { stdin = data, text = false }):wait()
  return res.code == 0 and res.stdout or nil
end

---@class cc.Image
---@field media_type string
---@field data string base64

--- The image in the clipboard, if it holds one
---@return cc.Image?
---@return string? error
function M.from_clipboard()
  local list, read = backend()
  if not list or not read then
    return nil, 'no clipboard tool, needs wl-paste (Wayland) or xclip (X11)'
  end
  local types = list() or ''
  local found
  for t in types:gmatch '[^\n]+' do
    t = vim.trim(t)
    if SUPPORTED[t] then
      found = found or t
      if t == 'image/png' then
        found = t
        break
      end
    elseif not found and t:match '^image/' then
      found = t
    end
  end
  if not found then
    return nil
  end
  local data = read(found)
  if not data then
    return nil, 'cannot read the clipboard image'
  end
  if not SUPPORTED[found] or #data > MAX_BYTES then
    data = shrink(data)
    found = 'image/png'
    if not data or #data > MAX_BYTES then
      return nil, 'image too large or in an unsupported format, ImageMagick could not convert it'
    end
  end
  return { media_type = found, data = vim.base64.encode(data) }
end

return M
