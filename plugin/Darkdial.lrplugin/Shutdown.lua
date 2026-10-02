--[[----------------------------------------------------------------------------
Shutdown.lua
Runs when the plugin is disabled, reloaded or removed: stops the main loop in
Client.lua and closes both sockets so the ports are free for the next load.

This file is part of Darkdial, licensed under the GNU General Public License
v3.0 or later. See LICENSE for details.
------------------------------------------------------------------------------]]

-- Darkdial is unset if Client.lua failed to load.
if Darkdial and Darkdial.RUNNING then
  Darkdial.RUNNING = false
  if Darkdial.SENDER then
    Darkdial.SENDER:close()
  end
  if Darkdial.RECEIVER then
    Darkdial.RECEIVER:close()
  end
end
