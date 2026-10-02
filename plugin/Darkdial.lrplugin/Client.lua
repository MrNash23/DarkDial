--[[----------------------------------------------------------------------------
Client.lua
Darkdial plugin main file. Translates between the line protocol of the Darkdial
desktop service (docs/PROTOCOL.md, section 2) and the Lightroom SDK. All logic
such as step sizes and units lives in the service; this file only reads, sets
and reports Develop values.

This file is part of Darkdial. Darkdial is free software: you can redistribute
it and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for details.
------------------------------------------------------------------------------]]

local LrApplication       = import 'LrApplication'
local LrApplicationView   = import 'LrApplicationView'
local LrDate              = import 'LrDate'
local LrDevelopController = import 'LrDevelopController'
local LrFileUtils         = import 'LrFileUtils'
local LrFunctionContext   = import 'LrFunctionContext'
local LrLogger            = import 'LrLogger'
local LrPathUtils         = import 'LrPathUtils'
local LrSocket            = import 'LrSocket'
local LrTasks             = import 'LrTasks'

local Json = require 'Json'

local PROTOCOL_VERSION = '1.1'
local SEND_PORT        = 54770 -- plugin -> service
local RECEIVE_PORT     = 54771 -- service -> plugin
local POLL_INTERVAL    = 0.25  -- seconds, module and photo changes
local OBSERVER_INTERVAL = 0.03 -- seconds, minimum between two change scans
local MODULE_SWITCH_TIMEOUT = 3 -- seconds

-- Writes ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/Darkdial.log. Only start-up, connection
-- changes and errors are logged, so the file stays small.
local log = LrLogger('Darkdial')
log:enable('logfile')

local function readVersion()
  local text = LrFileUtils.readFile(LrPathUtils.child(_PLUGIN.path, 'version.txt'))
  return text and text:match('%S+') or '0.0.0'
end

-- Global so Shutdown.lua can stop this instance when the plugin is reloaded.
Darkdial = { RUNNING = true, OBSERVER = {} }

local sendConnected = false
local watched = {}        -- array of parameter names
local lastValue = {}      -- name -> last reported value
local lastRange = {}      -- name -> { min, max }
local state = { module = nil, photoId = nil }
local lastSource = nil    -- kind .. id of the source last reported
local lastScan = 0

local function send(message)
  if sendConnected and Darkdial.SENDER then
    Darkdial.SENDER:send(Json.encode(message) .. '\n')
  end
end

local function inDevelop()
  return LrApplicationView.getCurrentModuleName() == 'develop'
end

local function targetPhotoId()
  local photo = LrApplication.activeCatalog():getTargetPhoto()
  return photo and photo.localIdentifier or nil
end

local function canEdit()
  return inDevelop() and targetPhotoId() ~= nil
end

-- LrDevelopController throws for unknown parameters; a bad name from the
-- service must not take the receive loop down.
local function getValue(param)
  local ok, value = pcall(LrDevelopController.getValue, param)
  if ok and type(value) == 'number' then return value end
  return nil
end

local function getRange(param)
  local ok, min, max = pcall(LrDevelopController.getRange, param)
  if ok and type(min) == 'number' and type(max) == 'number' then return min, max end
  return nil
end

local function reportRange(param, force)
  local min, max = getRange(param)
  if not min then return end
  local known = lastRange[param]
  if force or not known or known[1] ~= min or known[2] ~= max then
    lastRange[param] = { min, max }
    send { t = 'range', p = param, min = min, max = max }
  end
end

local function reportValue(param, force, seq)
  local value = getValue(param)
  if not value then return end
  if force or seq or lastValue[param] ~= value then
    lastValue[param] = value
    send { t = 'value', p = param, v = value, s = seq }
  end
end

--- Reports ranges and values of all watched parameters that changed.
local function reportChanges(force)
  if not canEdit() then return end
  for _, param in ipairs(watched) do
    reportRange(param, force)
    reportValue(param, force)
  end
end

local function reportStatus()
  send {
    t = 'status',
    module = state.module or '',
    photo = state.photoId ~= nil,
    photoId = state.photoId,
  }
end

--- Where the photos on screen come from: the collection or folder selected
--- in the Library, otherwise the folder of the target photo. Returns kind,
--- name, id; kind is '' if there is none.
local function currentSource()
  local catalog = LrApplication.activeCatalog()
  local ok, sources = pcall(function() return catalog:getActiveSources() end)
  if ok and type(sources) == 'table' and #sources == 1 and type(sources[1]) == 'table' then
    local source = sources[1]
    local kind = source:type()
    if kind == 'LrCollection' or kind == 'LrPublishedCollection' then
      return 'collection', source:getName(), tostring(source.localIdentifier)
    elseif kind == 'LrFolder' then
      return 'folder', source:getName(), source:getPath()
    end
  end
  local photo = catalog:getTargetPhoto()
  if photo then
    local okPath, path = pcall(function() return photo:getRawMetadata('path') end)
    if okPath and type(path) == 'string' then
      local folder = LrPathUtils.parent(path)
      if folder then return 'folder', LrPathUtils.leafName(folder), folder end
    end
  end
  return '', '', ''
end

--- Reports the source if it changed (time tracking: the service suggests the
--- job that belongs to it).
local function pollSource(force)
  local kind, name, id = currentSource()
  local key = kind .. '\n' .. id
  if force or key ~= lastSource then
    lastSource = key
    send { t = 'source', kind = kind, name = name, id = id }
  end
end

--- Sends status if module or photo changed. Returns true if it did.
local function pollStatus(force)
  local module = LrApplicationView.getCurrentModuleName()
  local photoId = targetPhotoId()
  if force or module ~= state.module or photoId ~= state.photoId then
    state.module, state.photoId = module, photoId
    reportStatus()
    return true
  end
  return false
end

local function applyValue(param, value, delta, seq, reset)
  local min, max = getRange(param)
  if not min then return end
  if reset then
    local ok, err = pcall(LrDevelopController.resetToDefault, param)
    if not ok then
      log:warn('resetToDefault failed for ' .. tostring(param) .. ': ' .. tostring(err))
    end
    reportValue(param, false, seq)
    return
  end
  if delta then
    local current = getValue(param)
    if not current then return end
    value = current + delta
  end
  if type(value) ~= 'number' then return end
  value = math.max(min, math.min(max, value))
  local ok, err = pcall(LrDevelopController.setValue, param, value)
  if not ok then
    log:warn('setValue failed for ' .. tostring(param) .. ': ' .. tostring(err))
  end
  reportValue(param, false, seq)
end

--- Applies set/delta/reset; switches to the Develop module first if necessary.
local function change(param, value, delta, seq, reset)
  if type(param) ~= 'string' then return end
  if inDevelop() then
    if targetPhotoId() then applyValue(param, value, delta, seq, reset) end
    return
  end
  if not targetPhotoId() then return end
  -- Waiting for the module switch needs a task; the socket callback must not block.
  LrTasks.startAsyncTask(function()
    LrApplicationView.switchToModule('develop')
    local waited = 0
    while not inDevelop() and waited < MODULE_SWITCH_TIMEOUT do
      LrTasks.sleep(0.1)
      waited = waited + 0.1
    end
    if not inDevelop() then return end
    LrTasks.sleep(0.2) -- Lightroom needs a moment before the controller follows
    pollStatus(false)
    applyValue(param, value, delta, seq, reset)
  end)
end

local handlers = {}

function handlers.hello(message)
  -- A new service instance knows nothing yet: forget what was reported.
  lastValue, lastRange = {}, {}
  send {
    t = 'hello',
    plugin = readVersion(),
    proto = PROTOCOL_VERSION,
    lr = LrApplication.versionString(),
  }
  pollStatus(true)
  pollSource(true)
end

function handlers.watch(message)
  watched = {}
  if type(message.p) == 'table' then
    for _, param in ipairs(message.p) do
      if type(param) == 'string' then watched[#watched + 1] = param end
    end
  end
  lastValue, lastRange = {}, {}
  reportChanges(true)
end

function handlers.set(message)
  change(message.p, message.v, nil, message.s)
end

function handlers.delta(message)
  change(message.p, nil, message.d, message.s)
end

function handlers.reset(message)
  change(message.p, nil, nil, message.s, true)
end

function handlers.get(message)
  if type(message.p) == 'string' and canEdit() then
    reportRange(message.p, true)
    reportValue(message.p, true)
  end
end

function handlers.track(message)
  if not inDevelop() then return end
  if type(message.p) == 'string' and message.p ~= '' then
    pcall(LrDevelopController.startTracking, message.p)
  else
    pcall(LrDevelopController.stopTracking)
  end
end

function handlers.ping()
  send { t = 'pong' }
end

local function onMessage(_, line)
  if type(line) ~= 'string' then return end
  local message, err = Json.decode(line)
  if type(message) ~= 'table' then
    log:warn('bad message: ' .. tostring(err))
    return
  end
  local handler = handlers[message.t]
  if not handler then return end -- unknown types are ignored by specification
  local ok, handlerErr = pcall(handler, message)
  if not ok then
    log:error('handler ' .. tostring(message.t) .. ' failed: ' .. tostring(handlerErr))
  end
end

log:info('loading plugin ' .. readVersion() .. ' in Lightroom ' .. LrApplication.versionString())

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('darkdial_sockets', function(context)
    -- Errors inside a task vanish silently otherwise.
    context:addFailureHandler(function(_, message)
      log:error('main task failed: ' .. tostring(message))
    end)

    local function startSender()
      Darkdial.SENDER = LrSocket.bind {
        functionContext = context,
        plugin = _PLUGIN,
        port = SEND_PORT,
        mode = 'send',
        onConnected = function()
          sendConnected = true
          Darkdial.CONNECTED = true
          log:info('service connected')
        end,
        onClosed = function()
          sendConnected = false
          Darkdial.CONNECTED = false
        end,
        onError = function(socket, err)
          sendConnected = false
          Darkdial.CONNECTED = false
          log:warn('send socket: ' .. tostring(err))
          if Darkdial.RUNNING then socket:reconnect() end
        end,
      }
    end

    Darkdial.RECEIVER = LrSocket.bind {
      functionContext = context,
      plugin = _PLUGIN,
      port = RECEIVE_PORT,
      mode = 'receive',
      onMessage = onMessage,
      onClosed = function(socket)
        if Darkdial.RUNNING then
          -- The service went away. Calling reconnect on the send socket from
          -- here hangs Lightroom, so it is closed and bound again instead.
          socket:reconnect()
          Darkdial.SENDER:close()
          startSender()
        end
      end,
      onError = function(socket, err)
        if err == 'timeout' then
          if Darkdial.RUNNING then socket:reconnect() end
        else
          log:warn('receive socket: ' .. tostring(err))
        end
      end,
    }

    startSender()
    log:info('listening on ports ' .. SEND_PORT .. ' and ' .. RECEIVE_PORT)

    local observing = false
    while Darkdial.RUNNING do
      local changed = pollStatus(false)
      pollSource(false)
      if canEdit() then
        if not observing then
          -- Registering only works once the Develop module has a photo.
          LrDevelopController.addAdjustmentChangeObserver(context, Darkdial.OBSERVER, function()
            local now = LrDate.currentTime()
            if now - lastScan >= OBSERVER_INTERVAL then
              lastScan = now
              reportChanges(false)
            end
          end)
          observing = true
        end
        if changed then
          LrTasks.sleep(0.2) -- controller still holds the previous photo right after a switch
        end
        -- Also catches the last change of a drag that the rate limit skipped.
        reportChanges(false)
      end
      LrTasks.sleep(POLL_INTERVAL)
    end
  end)
end)
