--[[----------------------------------------------------------------------------
Info.lua
Darkdial plugin manifest.

This file is part of Darkdial. Darkdial is free software: you can redistribute
it and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for details.
------------------------------------------------------------------------------]]

return {
  LrSdkVersion = 11.0,
  LrSdkMinimumVersion = 11.0,
  LrToolkitIdentifier = 'io.github.mrnash23.darkdial',
  LrPluginName = 'Darkdial',
  LrPluginInfoUrl = 'https://github.com/MrNash23/DarkDial',
  LrInitPlugin = 'Client.lua',
  LrForceInitPlugin = true,
  LrShutdownPlugin = 'Shutdown.lua',
  -- keep in sync with version.txt (checked by plugin/test/run.lua)
  VERSION = { major = 0, minor = 1, revision = 0 },
}
