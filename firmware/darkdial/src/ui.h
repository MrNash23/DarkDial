// The display: value ring, icon, short word, value. LVGL 9 only, no Arduino
// includes, so the same code renders on the host (firmware/host).
#pragma once
#include <stdint.h>

#include "core/device.h"

/// Builds the screen and shows the boot logo. `onTap` is called for a short
/// tap anywhere on the display, `onLongTouch` when a finger stays on it.
/// LVGL and a display must be initialised.
void ui_init(void (*onTap)(), void (*onLongTouch)(), uint32_t nowMs);

/// Brings the screen in line with `device`. Call from the LVGL thread.
void ui_update(const dd::Device &device, uint32_t nowMs);
