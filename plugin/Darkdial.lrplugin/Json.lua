--[[----------------------------------------------------------------------------
Json.lua
Minimal JSON encoder and decoder for the line protocol in docs/PROTOCOL.md.
Plain Lua 5.1, no Lightroom imports, so it also runs under a stock interpreter.

Numbers are always written and read with a decimal point, whatever the
process locale is (Lightroom on a German system formats with a comma).

This file is part of Darkdial, licensed under the GNU General Public License
v3.0 or later. See LICENSE for details.
------------------------------------------------------------------------------]]

local Json = {}

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return 'null'
  end
  return (string.format('%.10g', n):gsub(',', '.'))
end

local function isArray(t)
  local count = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    count = count + 1
  end
  return count == #t
end

local function encode(value)
  local kind = type(value)
  if kind == 'nil' then
    return 'null'
  elseif kind == 'boolean' then
    return value and 'true' or 'false'
  elseif kind == 'number' then
    return encodeNumber(value)
  elseif kind == 'string' then
    return encodeString(value)
  elseif kind == 'table' then
    local parts = {}
    if isArray(value) then
      for i = 1, #value do
        parts[i] = encode(value[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
      parts[i] = encodeString(k) .. ':' .. encode(value[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('cannot encode ' .. kind)
end

local UNESCAPES = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f',
  n = '\n', r = '\r', t = '\t',
}

local function utf8Char(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  return string.char(0xE0 + math.floor(code / 0x1000),
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function toNumber(text)
  -- tonumber follows the locale; retry with a decimal comma.
  return tonumber(text) or tonumber((text:gsub('%.', ',')))
end

local decodeValue

local function skipSpace(s, i)
  return s:find('[^ \t\r\n]', i) or #s + 1
end

local function decodeString(s, i)
  local parts = {}
  i = i + 1
  while true do
    local j = s:find('["\\]', i)
    if not j then error('unterminated string') end
    parts[#parts + 1] = s:sub(i, j - 1)
    if s:sub(j, j) == '"' then
      return table.concat(parts), j + 1
    end
    local esc = s:sub(j + 1, j + 1)
    if esc == 'u' then
      local code = tonumber(s:sub(j + 2, j + 5), 16)
      if not code then error('bad unicode escape') end
      parts[#parts + 1] = utf8Char(code)
      i = j + 6
    else
      local char = UNESCAPES[esc]
      if not char then error('bad escape') end
      parts[#parts + 1] = char
      i = j + 2
    end
  end
end

local function decodeArray(s, i)
  local result = {}
  i = skipSpace(s, i + 1)
  if s:sub(i, i) == ']' then return result, i + 1 end
  while true do
    local value
    value, i = decodeValue(s, i)
    result[#result + 1] = value
    i = skipSpace(s, i)
    local c = s:sub(i, i)
    if c == ']' then return result, i + 1 end
    if c ~= ',' then error('expected , or ]') end
    i = i + 1
  end
end

local function decodeObject(s, i)
  local result = {}
  i = skipSpace(s, i + 1)
  if s:sub(i, i) == '}' then return result, i + 1 end
  while true do
    i = skipSpace(s, i)
    if s:sub(i, i) ~= '"' then error('expected key') end
    local key
    key, i = decodeString(s, i)
    i = skipSpace(s, i)
    if s:sub(i, i) ~= ':' then error('expected :') end
    local value
    value, i = decodeValue(s, i + 1)
    result[key] = value
    i = skipSpace(s, i)
    local c = s:sub(i, i)
    if c == '}' then return result, i + 1 end
    if c ~= ',' then error('expected , or }') end
    i = i + 1
  end
end

decodeValue = function(s, i)
  i = skipSpace(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    return decodeObject(s, i)
  elseif c == '[' then
    return decodeArray(s, i)
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then
    return nil, i + 4
  end
  local text = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
  local number = text and toNumber(text)
  if not number then error('unexpected character at ' .. i) end
  return number, i + #text
end

--- Encodes a Lua value as JSON text.
function Json.encode(value)
  return encode(value)
end

--- Decodes JSON text. Returns the value, or nil and an error message.
function Json.decode(text)
  local ok, result = pcall(function()
    local value, i = decodeValue(text, 1)
    if skipSpace(text, i) <= #text then error('trailing characters') end
    return value
  end)
  if ok then return result end
  return nil, result
end

return Json
