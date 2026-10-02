--[[----------------------------------------------------------------------------
Plugin tests. Runs under LuaJIT / Lua 5.1 without Lightroom:

    cd plugin && luajit test/run.lua

Json.lua is tested directly. Client.lua is loaded against a small fake of the
Lightroom SDK (only what Client.lua uses), with the main loop driven step by
step as a coroutine.
------------------------------------------------------------------------------]]

package.path = 'Darkdial.lrplugin/?.lua;' .. package.path

local failures, checks = 0, 0

local function check(condition, name)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    print('FAIL ' .. name)
  end
end

local function equal(actual, expected, name)
  check(actual == expected, string.format('%s: expected %s, got %s', name, tostring(expected), tostring(actual)))
end

-- Json ------------------------------------------------------------------------

local Json = require 'Json'

equal(Json.encode { t = 'value', p = 'Exposure', v = 0.35, s = 7 },
  '{"p":"Exposure","s":7,"t":"value","v":0.35}', 'encode object')
equal(Json.encode { 'a', 'b' }, '["a","b"]', 'encode array')
equal(Json.encode { photo = true, module = 'develop' }, '{"module":"develop","photo":true}', 'encode bool')
equal(Json.encode { v = 50000 }, '{"v":50000}', 'encode large number')
equal(Json.encode { v = -0.05 }, '{"v":-0.05}', 'encode negative fraction')
equal(Json.encode { s = 'a"b\\c\n' }, '{"s":"a\\"b\\\\c\\n"}', 'encode escapes')

do
  local m = Json.decode('{"t":"set","p":"Exposure","v":-1.25,"s":12}')
  equal(m.t, 'set', 'decode t')
  equal(m.v, -1.25, 'decode number')
  equal(m.s, 12, 'decode integer')
  m = Json.decode(' { "t" : "watch" , "p" : [ "Exposure" , "Tint" ] } ')
  equal(#m.p, 2, 'decode array length')
  equal(m.p[2], 'Tint', 'decode array item')
  m = Json.decode('{"a":true,"b":false,"c":null,"d":1e3,"e":"S\\u00e4tt\\n"}')
  equal(m.a, true, 'decode true')
  equal(m.b, false, 'decode false')
  equal(m.c, nil, 'decode null')
  equal(m.d, 1000, 'decode exponent')
  equal(m.e, 'S\195\164tt\n', 'decode unicode escape')
  m = Json.decode('{"p":""}')
  equal(m.p, '', 'decode empty string')
  local bad, err = Json.decode('{"t":')
  check(bad == nil and err ~= nil, 'decode error is reported')
  check(Json.decode('{"t":"x"} trailing') == nil, 'decode rejects trailing text')
  local round = Json.decode(Json.encode { t = 'range', p = 'Temperature', min = 2000, max = 50000 })
  equal(round.max, 50000, 'round trip')
end

-- Fake Lightroom SDK ------------------------------------------------------------

local lr = {
  module = 'library',
  photoId = 11,
  values = { Exposure = 0, Contrast = 10, Temperature = 5500 },
  ranges = { Exposure = { -5, 5 }, Contrast = { -100, 100 }, Temperature = { 2000, 50000 } },
  time = 0,
  tracking = nil,
  observer = nil,
  sockets = {},
  sent = {},
  tasks = {},
}

local function startTask(fn)
  local task = coroutine.create(fn)
  lr.tasks[#lr.tasks + 1] = task
  local ok, err = coroutine.resume(task)
  if not ok then error(err, 0) end
end

--- Lets every sleeping task run until its next sleep.
local function step(seconds)
  lr.time = lr.time + (seconds or 0.25)
  for _, task in ipairs(lr.tasks) do
    if coroutine.status(task) == 'suspended' then
      local ok, err = coroutine.resume(task)
      if not ok then error(err, 0) end
    end
  end
end

local sdk = {
  LrApplication = {
    activeCatalog = function()
      return { getTargetPhoto = function()
        return lr.photoId and { localIdentifier = lr.photoId } or nil
      end }
    end,
    versionString = function() return '15.2' end,
  },
  LrApplicationView = {
    getCurrentModuleName = function() return lr.module end,
    switchToModule = function(name) lr.module = name end,
  },
  LrDate = { currentTime = function() return lr.time end },
  LrDevelopController = {
    getValue = function(param)
      if lr.module ~= 'develop' then error('not in develop') end
      if lr.values[param] == nil then error('unknown parameter') end
      return lr.values[param]
    end,
    setValue = function(param, value)
      if lr.values[param] == nil then error('unknown parameter') end
      lr.values[param] = value
    end,
    getRange = function(param)
      if lr.module ~= 'develop' then error('not in develop') end
      local r = lr.ranges[param]
      if not r then error('unknown parameter') end
      return r[1], r[2]
    end,
    startTracking = function(param) lr.tracking = param end,
    stopTracking = function() lr.tracking = nil end,
    addAdjustmentChangeObserver = function(_, _, fn) lr.observer = fn end,
  },
  LrFileUtils = {
    exists = function() return false end,
    readFile = function() return '0.1.1\n' end,
  },
  LrFunctionContext = {
    callWithContext = function(_, fn) return fn({ addFailureHandler = function() end }) end,
  },
  LrLogger = function()
    return { enable = function() end, info = function() end, warn = function() end, error = function() end }
  end,
  LrPathUtils = { child = function(a, b) return a .. '/' .. b end },
  LrSocket = {
    bind = function(options)
      local socket = { options = options, closed = false }
      function socket:send(text) lr.sent[#lr.sent + 1] = text end
      function socket:close() self.closed = true end
      function socket:reconnect() self.reconnected = true end
      lr.sockets[options.mode] = socket
      return socket
    end,
  },
  LrTasks = {
    startAsyncTask = startTask,
    sleep = function() coroutine.yield() end,
  },
}

function import(name) -- luacheck: ignore (global on purpose, as in Lightroom)
  return assert(sdk[name], 'SDK module not faked: ' .. name)
end
_PLUGIN = { path = 'Darkdial.lrplugin' }

--- Returns and clears everything the plugin sent, decoded.
local function drain()
  local messages = {}
  for i, text in ipairs(lr.sent) do
    check(text:sub(-1) == '\n', 'message ends with newline')
    messages[i] = Json.decode(text)
  end
  lr.sent = {}
  return messages
end

local function find(messages, kind, param)
  for _, m in ipairs(messages) do
    if m.t == kind and (param == nil or m.p == param) then return m end
  end
  return nil
end

local function receive(message)
  local socket = lr.sockets.receive
  socket.options.onMessage(socket, Json.encode(message))
end

-- Client ------------------------------------------------------------------------

dofile('Darkdial.lrplugin/Client.lua')

check(lr.sockets.receive ~= nil and lr.sockets.send ~= nil, 'both sockets bound')
equal(lr.sockets.send.options.port, 54770, 'send port')
equal(lr.sockets.receive.options.port, 54771, 'receive port')

-- Nothing is sent before the service connected to the send socket.
receive { t = 'ping' }
equal(#drain(), 0, 'silent while send socket is not connected')

lr.sockets.send.options.onConnected()

receive { t = 'hello', app = 'test', proto = '1.0' }
do
  local messages = drain()
  local hello = find(messages, 'hello')
  equal(hello and hello.plugin, '0.1.1', 'hello carries plugin version')
  equal(hello and hello.proto, '1.0', 'hello carries protocol version')
  equal(hello and hello.lr, '15.2', 'hello carries Lightroom version')
  local status = find(messages, 'status')
  equal(status and status.module, 'library', 'status module')
  equal(status and status.photo, true, 'status photo')
end

receive { t = 'ping' }
check(find(drain(), 'pong') ~= nil, 'ping answered')

receive { t = 'nonsense', x = 1 }
lr.sockets.receive.options.onMessage(lr.sockets.receive, 'not json')
equal(#drain(), 0, 'unknown and malformed messages are ignored')

-- Outside Develop a watch reports nothing.
receive { t = 'watch', p = { 'Exposure', 'Contrast' } }
equal(#drain(), 0, 'no values outside Develop')

-- A set outside Develop switches the module, then applies.
receive { t = 'set', p = 'Exposure', v = 1.5, s = 1 }
equal(lr.module, 'develop', 'set switches to Develop')
step(0.2)
step(0.2)
do
  local messages = drain()
  equal(lr.values.Exposure, 1.5, 'value applied after module switch')
  local status = find(messages, 'status')
  equal(status and status.module, 'develop', 'status after module switch')
  local value = find(messages, 'value', 'Exposure')
  equal(value and value.s, 1, 'answer carries the sequence number')
  equal(value and value.v, 1.5, 'answer carries the value')
  -- Meanwhile the main loop registered the observer and reported the watch list.
  check(lr.observer ~= nil, 'observer registered in Develop')
  local range = find(messages, 'range', 'Contrast')
  equal(range and range.min, -100, 'range reported')
  equal(find(messages, 'value', 'Contrast').v, 10, 'watched value reported')
end

-- Values are clamped to the range.
receive { t = 'set', p = 'Exposure', v = 99, s = 2 }
equal(find(drain(), 'value', 'Exposure').v, 5, 'set clamps to max')
receive { t = 'delta', p = 'Exposure', d = -0.5, s = 3 }
equal(find(drain(), 'value', 'Exposure').v, 4.5, 'delta adds to current value')

-- The plugin's own set must not be reported a second time by the observer.
lr.time = lr.time + 1
lr.observer()
equal(#drain(), 0, 'own set is not echoed twice')

-- A change made in Lightroom is reported without sequence number.
lr.values.Contrast = 42
lr.time = lr.time + 1
lr.observer()
do
  local messages = drain()
  equal(#messages, 1, 'one message for one change')
  equal(messages[1].p, 'Contrast', 'changed parameter reported')
  equal(messages[1].v, 42, 'changed value reported')
  equal(messages[1].s, nil, 'no sequence number for Lightroom changes')
end

-- A change skipped by the observer rate limit is picked up by the main loop.
lr.values.Contrast = 43
lr.observer() -- same timestamp as before: rate limited
equal(#drain(), 0, 'observer is rate limited')
step()
equal(find(drain(), 'value', 'Contrast').v, 43, 'main loop catches the skipped change')

-- Unknown parameter names do not break anything.
receive { t = 'set', p = 'NoSuchParam', v = 1, s = 4 }
receive { t = 'get', p = 'NoSuchParam' }
equal(#drain(), 0, 'unknown parameter is ignored')

receive { t = 'get', p = 'Temperature' }
do
  local messages = drain()
  equal(find(messages, 'range', 'Temperature').max, 50000, 'get reports range')
  equal(find(messages, 'value', 'Temperature').v, 5500, 'get reports value')
end

receive { t = 'track', p = 'Exposure' }
equal(lr.tracking, 'Exposure', 'tracking started')
receive { t = 'track', p = '' }
equal(lr.tracking, nil, 'tracking stopped')

-- Photo change: status, then range (raw vs JPEG) and values again.
lr.photoId = 12
lr.ranges.Temperature = { -100, 100 }
lr.values.Temperature = 0
receive { t = 'watch', p = { 'Temperature' } }
drain()
lr.photoId = 13
lr.ranges.Temperature = { 2000, 50000 }
lr.values.Temperature = 6000
step()
step()
do
  local messages = drain()
  equal(find(messages, 'status').photoId, 13, 'photo change reported')
  equal(find(messages, 'range', 'Temperature').max, 50000, 'range follows the photo')
  equal(find(messages, 'value', 'Temperature').v, 6000, 'value follows the photo')
end

-- No photo: status says so and set is ignored.
lr.photoId = nil
step()
equal(find(drain(), 'status').photo, false, 'no photo reported')
receive { t = 'set', p = 'Exposure', v = 0, s = 5 }
equal(#drain(), 0, 'set without photo is ignored')
lr.photoId = 13

-- Service disconnects: receive socket reconnects, send socket is rebound.
do
  local oldSender = lr.sockets.send
  lr.sockets.receive.options.onClosed(lr.sockets.receive)
  check(lr.sockets.receive.reconnected, 'receive socket reconnects')
  check(oldSender.closed, 'old send socket closed')
  check(lr.sockets.send ~= oldSender, 'send socket bound again')
end

-- Shutdown stops the loop and closes the sockets.
dofile('Darkdial.lrplugin/Shutdown.lua')
equal(Darkdial.RUNNING, false, 'shutdown clears RUNNING')
check(lr.sockets.receive.closed and lr.sockets.send.closed, 'shutdown closes sockets')
step()
equal(coroutine.status(lr.tasks[1]), 'dead', 'main loop ended')

-- Version in Info.lua matches version.txt.
do
  local info = dofile('Darkdial.lrplugin/Info.lua')
  local v = info.VERSION
  local file = io.open('Darkdial.lrplugin/version.txt')
  local text = file:read('*l')
  file:close()
  equal(string.format('%d.%d.%d', v.major, v.minor, v.revision), text, 'Info.lua VERSION matches version.txt')
end

print(string.format('%d checks, %d failed', checks, failures))
os.exit(failures == 0 and 0 or 1)
