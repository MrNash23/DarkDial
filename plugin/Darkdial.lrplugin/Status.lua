--[[----------------------------------------------------------------------------
Status.lua
Menu item "Darkdial: Status": tells whether the plugin is running and whether
the Darkdial desktop app is connected.

This file is part of Darkdial, licensed under the GNU General Public License
v3.0 or later. See LICENSE for details.
------------------------------------------------------------------------------]]

local LrDialogs = import 'LrDialogs'

local running = Darkdial and Darkdial.RUNNING
local connected = running and Darkdial.CONNECTED

local message
if not running then
  message = 'The plug-in is not running. Reload it in the Plug-in Manager.'
elseif connected then
  message = 'Connected to the Darkdial app.'
else
  message = 'Waiting for the Darkdial app (ports 54770 and 54771).'
end
LrDialogs.message('Darkdial', message, 'info')
