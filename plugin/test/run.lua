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
  defaults = { Exposure = 0, Contrast = 0, Temperature = 5200 },
  ranges = { Exposure = { -5, 5 }, Contrast = { -100, 100 }, Temperature = { 2000, 50000 } },
  time = 0,
  tracking = nil,
  observer = nil,
  sources = nil,           -- what catalog:getActiveSources() returns
  photoPath = '/Fotos/2026/Hochzeit/IMG_0001.dng',
  marks = {},              -- photo id -> { rating, pickStatus, colorNameForLabel }
  sockets = {},
  sent = {},
  tasks = {},
}

function lr.mark(key, value)
  lr.marks[lr.photoId] = lr.marks[lr.photoId] or {}
  lr.marks[lr.photoId][key] = value
end

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
      return {
        getTargetPhoto = function()
          if not lr.photoId then return nil end
          return {
            localIdentifier = lr.photoId,
            getRawMetadata = function(_, key)
              if key == 'path' then return lr.photoPath end
              return (lr.marks[lr.photoId] or {})[key]
            end,
            getFormattedMetadata = function(_, key)
              return key == 'fileName' and ('IMG_00' .. lr.photoId .. '.dng') or nil
            end,
          }
        end,
        getActiveSources = function() return lr.sources or { 'all_photographs' } end,
      }
    end,
    versionString = function() return '15.2' end,
  },
  LrApplicationView = {
    getCurrentModuleName = function() return lr.module end,
    switchToModule = function(name) lr.module = name end,
  },
  LrSelection = {
    nextPhoto = function() lr.photoId = lr.photoId + 1 end,
    previousPhoto = function() lr.photoId = lr.photoId - 1 end,
    flagAsPick = function() lr.mark('pickStatus', 1) end,
    flagAsReject = function() lr.mark('pickStatus', -1) end,
    removeFlag = function() lr.mark('pickStatus', 0) end,
    setRating = function(n) lr.mark('rating', n) end,
    setColorLabel = function(name) lr.mark('colorNameForLabel', name == 'none' and '' or name) end,
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
      -- Like the real Lightroom: the observer runs from inside setValue.
      if lr.observer then
        lr.time = lr.time + 1
        lr.observer()
      end
    end,
    getRange = function(param)
      if lr.module ~= 'develop' then error('not in develop') end
      local r = lr.ranges[param]
      if not r then error('unknown parameter') end
      return r[1], r[2]
    end,
    resetToDefault = function(param)
      if lr.values[param] == nil then error('unknown parameter') end
      lr.values[param] = lr.defaults[param]
      if lr.observer then
        lr.time = lr.time + 1
        lr.observer()
      end
    end,
    startTracking = function(param) lr.tracking = param end,
    stopTracking = function() lr.tracking = nil end,
    addAdjustmentChangeObserver = function(_, _, fn) lr.observer = fn end,
  },
  LrFileUtils = {
    exists = function() return false end,
    readFile = function() return '0.4.1\n' end,
  },
  LrFunctionContext = {
    callWithContext = function(_, fn) return fn({ addFailureHandler = function() end }) end,
  },
  LrLogger = function()
    return { enable = function() end, info = function() end, warn = function() end, error = function() end }
  end,
  LrPathUtils = {
    child = function(a, b) return a .. '/' .. b end,
    parent = function(path) return path:match('^(.*)/[^/]+$') end,
    leafName = function(path) return path:match('([^/]+)$') end,
  },
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
    canYield = function() return coroutine.running() ~= nil end,
    pcall = pcall,
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
  equal(hello and hello.plugin, '0.4.1', 'hello carries plugin version')
  equal(hello and hello.proto, '1.3', 'hello carries protocol version')
  equal(hello and hello.lr, '15.2', 'hello carries Lightroom version')
  local status = find(messages, 'status')
  equal(status and status.module, 'library', 'status module')
  equal(status and status.photo, true, 'status photo')
  -- No collection or folder selected: the folder of the target photo.
  local source = find(messages, 'source')
  equal(source and source.kind, 'folder', 'source falls back to the photo folder')
  equal(source and source.name, 'Hochzeit', 'folder name')
  equal(source and source.id, '/Fotos/2026/Hochzeit', 'folder path as id')
end

-- Selecting a collection, then a folder, is reported once each.
lr.sources = { {
  type = function() return 'LrCollection' end,
  getName = function() return 'Hochzeit Auswahl' end,
  localIdentifier = 77,
} }
step()
do
  local messages = drain()
  local source = find(messages, 'source')
  equal(source and source.kind, 'collection', 'collection reported')
  equal(source and source.name, 'Hochzeit Auswahl', 'collection name')
  equal(source and source.id, '77', 'collection id as string')
end
step()
equal(find(drain(), 'source'), nil, 'unchanged source is not repeated')
lr.sources = { {
  type = function() return 'LrFolder' end,
  getName = function() return '2026' end,
  getPath = function() return '/Fotos/2026' end,
} }
step()
equal(find(drain(), 'source').id, '/Fotos/2026', 'folder reported with its path')
lr.sources = nil
step()
drain()

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

-- Values are clamped to the range. A set from the service is answered once,
-- with its sequence number, and is not mistaken for the user moving a slider.
receive { t = 'set', p = 'Exposure', v = 99, s = 2 }
do
  local messages = drain()
  equal(#messages, 1, 'one answer per set')
  equal(messages[1].v, 5, 'set clamps to max')
  equal(messages[1].s, 2, 'the answer carries the sequence number')
  equal(find(messages, 'touched'), nil, 'a set from the service is not touched')
end
receive { t = 'delta', p = 'Exposure', d = -0.5, s = 3 }
equal(find(drain(), 'value', 'Exposure').v, 4.5, 'delta adds to current value')

-- Reset goes back to Lightroom's default and answers like a set.
receive { t = 'reset', p = 'Exposure', s = 30 }
do
  local value = find(drain(), 'value', 'Exposure')
  equal(value and value.v, 0, 'reset restores the default')
  equal(value and value.s, 30, 'reset answer carries the sequence number')
end
receive { t = 'set', p = 'Exposure', v = 4.5, s = 31 }
drain()

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
  equal(#messages, 2, 'value and touched for one change')
  equal(messages[1].p, 'Contrast', 'changed parameter reported')
  equal(messages[1].v, 42, 'changed value reported')
  equal(messages[1].s, nil, 'no sequence number for Lightroom changes')
  -- One slider moved by hand: the device may follow it.
  equal(messages[2].t, 'touched', 'single change is reported as touched')
  equal(messages[2].p, 'Contrast', 'touched names the slider')
end

-- Two sliders at once (a preset, auto tone) are nobody's single move.
receive { t = 'watch', p = { 'Exposure', 'Contrast' } }
drain()
lr.values.Contrast = 5
lr.values.Exposure = 1
lr.time = lr.time + 1
lr.observer()
do
  local messages = drain()
  equal(#messages, 2, 'two values')
  equal(find(messages, 'touched'), nil, 'several changes are not touched')
end
lr.values.Contrast = 42
lr.values.Exposure = 4.5
lr.time = lr.time + 1
lr.observer()
drain()

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
  equal(find(messages, 'touched'), nil, 'another photo is not a touched slider')
  equal(find(messages, 'status').photoId, 13, 'photo change reported')
  equal(find(messages, 'range', 'Temperature').max, 50000, 'range follows the photo')
  equal(find(messages, 'value', 'Temperature').v, 6000, 'value follows the photo')
end

-- Library: the status carries what the device shows of the photo.
lr.module = 'library'
step()
do
  local status = find(drain(), 'status')
  equal(status.module, 'library', 'library reported')
  equal(status.name, 'IMG_0013.dng', 'file name in status')
  equal(status.rating, 0, 'no stars yet')
  equal(status.flag, 0, 'no flag yet')
  equal(status.label, '', 'no colour label yet')
end
-- Browsing: so many photos on or back, answered with the new status.
receive { t = 'photo', d = 2 }
do
  local status = find(drain(), 'status')
  equal(lr.photoId, 15, 'two photos on')
  equal(status.photoId, 15, 'browsing reported')
  equal(status.name, 'IMG_0015.dng', 'name follows')
end
receive { t = 'photo', d = -1 }
equal(find(drain(), 'status').photoId, 14, 'one photo back')
receive { t = 'photo', d = 500 }
equal(lr.photoId, 34, 'steps per message are limited')
drain()
receive { t = 'photo', d = 0 }
receive { t = 'photo' }
equal(#drain(), 0, 'no step, no answer')
-- Marks: flag, stars, colour label; each answered with the status.
receive { t = 'mark', k = 'flag', v = 1 }
equal(find(drain(), 'status').flag, 1, 'picked')
receive { t = 'mark', k = 'flag', v = -1 }
equal(find(drain(), 'status').flag, -1, 'rejected')
receive { t = 'mark', k = 'flag', v = 0 }
equal(find(drain(), 'status').flag, 0, 'flag removed')
receive { t = 'mark', k = 'rating', v = 3 }
equal(find(drain(), 'status').rating, 3, 'three stars')
receive { t = 'mark', k = 'rating', v = 9 }
equal(find(drain(), 'status').rating, 5, 'stars are limited to five')
receive { t = 'mark', k = 'label', v = 'green' }
equal(find(drain(), 'status').label, 'green', 'green label')
receive { t = 'mark', k = 'label', v = 'none' }
equal(find(drain(), 'status').label, '', 'label removed')
receive { t = 'mark', k = 'label', v = 'pink' }
receive { t = 'mark', k = 'nonsense', v = 1 }
equal(#drain(), 0, 'unknown marks are ignored')
-- A mark with `next` goes on to the next photo; the mark stays on the old one.
do
  local before = lr.photoId
  receive { t = 'mark', k = 'rating', v = 4, next = true }
  local status = find(drain(), 'status')
  equal(lr.marks[before].rating, 4, 'mark set on the photo that was selected')
  equal(lr.photoId, before + 1, 'next photo selected after the mark')
  equal(status.photoId, before + 1, 'status is of the next photo')
  equal(status.rating, 0, 'which has no stars')
end
-- A mark set in Lightroom itself is noticed by the poll.
lr.mark('rating', 2)
step()
equal(find(drain(), 'status').rating, 2, 'rating changed in Lightroom is reported')
step()
equal(#drain(), 0, 'and only once')
-- Module switch asked for by the knob.
receive { t = 'module', m = 'develop' }
equal(lr.module, 'develop', 'switched to develop')
receive { t = 'module', m = 'map' }
equal(lr.module, 'develop', 'other modules are not switched to')
receive { t = 'module', m = 'library' }
equal(lr.module, 'library', 'switched to the library')
lr.module = 'develop'
lr.photoId = 13
step()
step()
drain()

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

-- The Plug-in Manager section builds with a minimal view factory.
do
  local provider = dofile('Darkdial.lrplugin/PluginInfo.lua')
  local factory = { row = function(_, t) return t end, static_text = function(_, t) return t end }
  local sections = provider.sectionsForTopOfDialog(factory, {})
  equal(sections[1].title, 'Darkdial', 'plug-in manager section')
  check(sections[1][1][1].title:find('meine%-belichtungszeit%.de') ~= nil, 'powered-by line')
end

print(string.format('%d checks, %d failed', checks, failures))
os.exit(failures == 0 and 0 or 1)
