--[[----------------------------------------------------------------------------
PluginInfo.lua
Section shown for Darkdial in Lightroom's Plug-in Manager.

This file is part of Darkdial, licensed under the GNU General Public License
v3.0 or later. See LICENSE for details.
------------------------------------------------------------------------------]]

return {
  sectionsForTopOfDialog = function(f, _)
    return {
      {
        title = 'Darkdial',
        f:row {
          f:static_text {
            title = 'Rotary controller for Lightroom Classic.\npowered by meine-belichtungszeit.de',
            height_in_lines = 2,
            fill_horizontal = 1,
          },
        },
      },
    }
  end,
}
