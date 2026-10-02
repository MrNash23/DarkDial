#include "ui.h"

#include <lvgl.h>
#include <stdio.h>

#include "core/params.h"
#include "icons.h"

extern "C" {
extern const lv_font_t dd_font_label;
extern const lv_font_t dd_font_value;
extern const lv_font_t dd_font_small;
}

namespace {

// Geometry and colours shared with the preview in the desktop app
// (app/lib/ui/dial_preview.dart); keep both in sync.
constexpr int kDisplaySize = 360;
constexpr int kRingMargin = 6;
constexpr int kRingWidth = 14;
constexpr int kRingStartDeg = 120;  // the 60° gap is centred at 6 o'clock
constexpr int kRingSweepDeg = 300;
constexpr int kRingTopDeg = 270;
constexpr int kIconTop = 61;
constexpr int kLabelTop = 184;
constexpr int kValueTop = 234;
constexpr int kGapTimeBottom = 10;
constexpr int kMenuTitleTop = 30;   // page title of the time tracking menu  // the running time sits in the gap of the ring
// The ring only starts to fill after this part of the long press, so a
// normal click does not flash it.
constexpr float kHoldVisibleFrom = 0.2f;
constexpr uint32_t kColorTrack = 0x26262B;
constexpr uint32_t kColorSelect = 0x8A8A90;
constexpr uint32_t kColorAccent = 0xFF9F0A;
constexpr uint32_t kColorLabel = 0xB8B8BE;
constexpr uint32_t kBootLogoMs = 3000;   // the Darkdial logo
constexpr uint32_t kPoweredByMs = 3000;  // then "powered by" with its logo, never both together
constexpr int kPoweredByTextTop = 44;
constexpr int kPoweredByLogoTop = 92;
constexpr uint32_t kSlideMs = 160;
constexpr int kSlideDistance = 90;

lv_obj_t *ring = nullptr;
lv_obj_t *iconBox = nullptr;
lv_obj_t *icon = nullptr;
lv_obj_t *dot = nullptr;
lv_obj_t *label = nullptr;
lv_obj_t *value = nullptr;
lv_obj_t *gapTime = nullptr;
lv_obj_t *menuTitle = nullptr;
lv_obj_t *logo = nullptr;
lv_obj_t *poweredBy = nullptr;

void (*tapHandler)() = nullptr;
void (*longTouchHandler)() = nullptr;
uint32_t bootMs = 0;
uint32_t shownRevision = UINT32_MAX;
int shownIndex = -1;
int shownHold = 0;

void onScreenClicked(lv_event_t *) {
  if (tapHandler) tapHandler();
}

void onScreenLongPressed(lv_event_t *) {
  if (longTouchHandler) longTouchHandler();
}

void setTranslateX(void *object, int32_t x) {
  lv_obj_set_style_translate_x(static_cast<lv_obj_t *>(object), x, 0);
}

void setOpacity(void *object, int32_t opacity) {
  lv_obj_set_style_opa(static_cast<lv_obj_t *>(object), static_cast<lv_opa_t>(opacity), 0);
}

void setRingOpacity(void *object, int32_t opacity) {
  lv_obj_set_style_arc_opa(static_cast<lv_obj_t *>(object), static_cast<lv_opa_t>(opacity), LV_PART_INDICATOR);
}

void animate(lv_obj_t *object, lv_anim_exec_xcb_t exec, int32_t from, int32_t to, uint32_t ms) {
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, object);
  lv_anim_set_exec_cb(&a, exec);
  lv_anim_set_values(&a, from, to);
  lv_anim_set_duration(&a, ms);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_start(&a);
}

/// Icon slides in from the side it was turned to; with a value ring, that
/// fades over.
void startSlide(int direction, bool withRing) {
  animate(iconBox, setTranslateX, direction * kSlideDistance, 0, kSlideMs);
  animate(iconBox, setOpacity, LV_OPA_TRANSP, LV_OPA_COVER, kSlideMs);
  if (withRing) animate(ring, setRingOpacity, LV_OPA_TRANSP, LV_OPA_COVER, kSlideMs + 60);
}

void setIcon(uint8_t iconId) {
  const lv_image_dsc_t *image = iconId < DD_ICON_TABLE_SIZE ? dd_icons[iconId] : nullptr;
  if (image) {
    lv_image_set_src(icon, image);
    lv_obj_set_hidden(icon, false);
  } else {
    lv_obj_set_hidden(icon, true);
  }
}

void hideIndicator() {
  lv_anim_delete(ring, setRingOpacity);
  lv_obj_set_style_arc_opa(ring, LV_OPA_TRANSP, LV_PART_INDICATOR);
}

/// Ring indicator for `position`: bipolar from the top, unipolar from the start.
void showIndicator(uint16_t position, bool bipolar, uint32_t color) {
  int start;
  int end;
  if (bipolar) {
    const int delta = (static_cast<int>(position) - dd::kPositionCentre) * kRingSweepDeg / dd::kPositionMax;
    if (delta > 0) {
      start = kRingTopDeg;
      end = kRingTopDeg + delta;
    } else if (delta < 0) {
      start = kRingTopDeg + delta;
      end = kRingTopDeg;
    } else {  // neutral: a dot at the top
      start = kRingTopDeg - 1;
      end = kRingTopDeg + 1;
    }
  } else {
    int sweep = static_cast<int>(position) * kRingSweepDeg / dd::kPositionMax;
    if (sweep < 1) sweep = 1;
    start = kRingStartDeg;
    end = kRingStartDeg + sweep;
  }
  lv_arc_set_angles(ring, static_cast<lv_value_precise_t>(start % 360), static_cast<lv_value_precise_t>(end % 360));
  lv_obj_set_style_arc_color(ring, lv_color_hex(color), LV_PART_INDICATOR);
  if (!lv_anim_get(ring, setRingOpacity)) lv_obj_set_style_arc_opa(ring, LV_OPA_COVER, LV_PART_INDICATOR);
}

/// A screen without slot: icon, one line of text, optionally a big value.
void showMessage(uint8_t iconId, const char *text, const char *big = "") {
  setIcon(iconId);
  lv_obj_set_hidden(dot, true);
  lv_label_set_text(label, text);
  lv_label_set_text(value, big);
  hideIndicator();
}

void showStatus(uint8_t iconId, uint8_t language) {
  const char *text = "";
  for (const dd::StatusText &status : dd::kStatusText) {
    if (status.icon == iconId) text = language == 0 ? status.de : status.en;
  }
  showMessage(iconId, text);
}

const char *timerText(dd::TimerTextId id, uint8_t language) {
  return language == 0 ? dd::kTimerText[id].de : dd::kTimerText[id].en;
}

/// The time tracking menu: one line of the page at a time, like the
/// carousel, with the page title on top and the position on the ring.
void showMenu(const dd::Device &device, uint32_t nowMs) {
  if (!device.serviceConnected()) {
    showStatus(dd::ICON_STATUS_OFFLINE, device.language());
    return;
  }
  lv_label_set_text(menuTitle, device.menuTitle());
  if (device.menuCount() == 0) {
    // Just opened: the page is on its way.
    showMessage(dd::ICON_TIMER_STOPWATCH, "");
    return;
  }
  const dd::MenuItem &item = device.menuItem(device.menuIndex());
  char time[12] = "";
  if (item.running && device.timerRunning()) dd::formatElapsed(device.timerSeconds(nowMs), time);
  char text[dd::kMaxLabelBytes + 4];
  // "»" (Latin-1) marks a line that leads to another page.
  snprintf(text, sizeof(text), item.submenu ? "%s \xC2\xBB" : "%s", item.label);
  showMessage(item.icon, text, time);
  if (item.highlighted) lv_obj_set_style_text_color(label, lv_color_hex(kColorAccent), 0);

  // Where we are in the list: one segment of the ring per line.
  if (device.menuCount() > 1) {
    const int segment = kRingSweepDeg / device.menuCount();
    const int start = kRingStartDeg + device.menuIndex() * kRingSweepDeg / device.menuCount();
    lv_arc_set_angles(ring, static_cast<lv_value_precise_t>(start % 360),
                      static_cast<lv_value_precise_t>((start + (segment < 6 ? 6 : segment)) % 360));
    lv_obj_set_style_arc_color(ring, lv_color_hex(kColorSelect), LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(ring, LV_OPA_COVER, LV_PART_INDICATOR);
  }
}

void showTimerNotice(const dd::Device &device) {
  if (device.noticeCode() == 0) {
    showMessage(dd::ICON_TIMER_STOPWATCH, timerText(dd::TEXT_STARTED, device.language()));
  } else if (device.noticeCode() == 1) {
    showMessage(dd::ICON_TIMER_STOP, timerText(dd::TEXT_STOPPED, device.language()));
  } else {
    showMessage(dd::ICON_STATUS_OFFLINE, device.noticeText());
  }
}

void showSlot(const dd::Device &device) {
  const dd::Slot &slot = device.slot(device.index());
  const dd::SlotValue &current = device.value(device.index());
  setIcon(slot.iconId);
  if (slot.hasColor()) {
    lv_obj_set_style_bg_color(dot, lv_color_make(slot.r, slot.g, slot.b), 0);
    lv_obj_set_hidden(dot, false);
  } else {
    lv_obj_set_hidden(dot, true);
  }
  lv_label_set_text(label, slot.label);
  lv_label_set_text(value, current.valid ? current.text : "--");

  if (!current.valid || !device.lightroomConnected()) {
    hideIndicator();
    return;
  }
  uint32_t color = kColorSelect;
  if (device.mode() == dd::Mode::Edit) {
    color = slot.hasColor() ? (static_cast<uint32_t>(slot.r) << 16 | static_cast<uint32_t>(slot.g) << 8 | slot.b)
                            : kColorAccent;
  }
  showIndicator(current.position, slot.bipolar, color);
}

}  // namespace

void ui_init(void (*onTap)(), void (*onLongTouch)(), uint32_t nowMs) {
  tapHandler = onTap;
  longTouchHandler = onLongTouch;
  bootMs = nowMs;
  shownRevision = UINT32_MAX;
  shownIndex = -1;
  shownHold = 0;

  lv_obj_t *screen = lv_screen_active();
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
  lv_obj_set_scrollable(screen, false);
  // SHORT_CLICKED, not CLICKED: the latter also fires after a long touch.
  lv_obj_add_event_cb(screen, onScreenClicked, LV_EVENT_SHORT_CLICKED, nullptr);
  lv_obj_add_event_cb(screen, onScreenLongPressed, LV_EVENT_LONG_PRESSED, nullptr);

  ring = lv_arc_create(screen);
  lv_obj_set_size(ring, kDisplaySize - 2 * kRingMargin, kDisplaySize - 2 * kRingMargin);
  lv_obj_center(ring);
  lv_arc_set_bg_angles(ring, kRingStartDeg, (kRingStartDeg + kRingSweepDeg) % 360);
  lv_obj_remove_style(ring, nullptr, LV_PART_KNOB);
  // Taps anywhere, also on the ring, belong to the screen.
  lv_obj_set_clickable(ring, false);
  lv_obj_set_style_arc_width(ring, kRingWidth, LV_PART_MAIN);
  lv_obj_set_style_arc_width(ring, kRingWidth, LV_PART_INDICATOR);
  lv_obj_set_style_arc_rounded(ring, true, LV_PART_MAIN);
  lv_obj_set_style_arc_rounded(ring, true, LV_PART_INDICATOR);
  lv_obj_set_style_arc_color(ring, lv_color_hex(kColorTrack), LV_PART_MAIN);
  lv_obj_set_style_arc_opa(ring, LV_OPA_TRANSP, LV_PART_INDICATOR);

  // Icon and colour dot move together in the slide animation.
  iconBox = lv_obj_create(screen);
  lv_obj_remove_style_all(iconBox);
  lv_obj_set_size(iconBox, DD_ICON_SIZE, DD_ICON_SIZE);
  lv_obj_align(iconBox, LV_ALIGN_TOP_MID, 0, kIconTop);
  lv_obj_set_clickable(iconBox, false);
  lv_obj_set_scrollable(iconBox, false);

  icon = lv_image_create(iconBox);
  lv_obj_set_pos(icon, 0, 0);

  dot = lv_obj_create(iconBox);
  lv_obj_remove_style_all(dot);
  lv_obj_set_size(dot, 2 * DD_HSL_DOT_R, 2 * DD_HSL_DOT_R);
  lv_obj_set_pos(dot, DD_HSL_DOT_X - DD_HSL_DOT_R, DD_HSL_DOT_Y - DD_HSL_DOT_R);
  lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(dot, LV_OPA_COVER, 0);
  lv_obj_set_clickable(dot, false);
  lv_obj_set_hidden(dot, true);

  label = lv_label_create(screen);
  lv_obj_set_style_text_font(label, &dd_font_label, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(kColorLabel), 0);
  lv_obj_align(label, LV_ALIGN_TOP_MID, 0, kLabelTop);
  lv_label_set_text(label, "");

  value = lv_label_create(screen);
  lv_obj_set_style_text_font(value, &dd_font_value, 0);
  lv_obj_set_style_text_color(value, lv_color_white(), 0);
  lv_obj_align(value, LV_ALIGN_TOP_MID, 0, kValueTop);
  lv_label_set_text(value, "");

  gapTime = lv_label_create(screen);
  lv_obj_set_style_text_font(gapTime, &dd_font_small, 0);
  lv_obj_set_style_text_color(gapTime, lv_color_hex(kColorLabel), 0);
  lv_obj_align(gapTime, LV_ALIGN_BOTTOM_MID, 0, -kGapTimeBottom);
  lv_label_set_text(gapTime, "");

  // Second splash screen: covers everything, hidden until the logo is gone.
  poweredBy = lv_obj_create(screen);
  lv_obj_remove_style_all(poweredBy);
  lv_obj_set_size(poweredBy, kDisplaySize, kDisplaySize);
  lv_obj_set_style_bg_color(poweredBy, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(poweredBy, LV_OPA_COVER, 0);
  lv_obj_set_clickable(poweredBy, false);
  lv_obj_set_scrollable(poweredBy, false);
  lv_obj_t *poweredByText = lv_label_create(poweredBy);
  lv_obj_set_style_text_font(poweredByText, &dd_font_label, 0);
  lv_obj_set_style_text_color(poweredByText, lv_color_hex(kColorLabel), 0);
  lv_label_set_text(poweredByText, "powered by");
  lv_obj_align(poweredByText, LV_ALIGN_TOP_MID, 0, kPoweredByTextTop);
  lv_obj_t *poweredByLogo = lv_image_create(poweredBy);
  lv_image_set_src(poweredByLogo, &dd_powered_by);
  lv_obj_align(poweredByLogo, LV_ALIGN_TOP_MID, 0, kPoweredByLogoTop);
  lv_obj_set_hidden(poweredBy, true);

  menuTitle = lv_label_create(screen);
  lv_obj_set_style_text_font(menuTitle, &dd_font_small, 0);
  lv_obj_set_style_text_color(menuTitle, lv_color_hex(kColorSelect), 0);
  lv_obj_align(menuTitle, LV_ALIGN_TOP_MID, 0, kMenuTitleTop);
  lv_label_set_text(menuTitle, "");

  logo = lv_image_create(screen);
  lv_image_set_src(logo, &dd_logo);
  lv_obj_center(logo);
}

void ui_update(const dd::Device &device, uint32_t nowMs) {
  if (logo && nowMs - bootMs >= kBootLogoMs) {
    lv_obj_delete(logo);
    logo = nullptr;
    lv_obj_set_hidden(poweredBy, false);
  }
  if (poweredBy && !logo && nowMs - bootMs >= kBootLogoMs + kPoweredByMs) {
    lv_obj_delete(poweredBy);
    poweredBy = nullptr;
  }
  // The ring fills while the knob is held towards the long press.
  const float progress = device.holdProgress(nowMs);
  const int hold = progress > kHoldVisibleFrom
                       ? 1 + static_cast<int>((progress - kHoldVisibleFrom) / (1 - kHoldVisibleFrom) * kRingSweepDeg)
                       : 0;
  if (device.revision() == shownRevision && hold == shownHold) return;
  shownRevision = device.revision();
  shownHold = hold;

  lv_obj_set_style_text_color(label, lv_color_hex(kColorLabel), 0);
  lv_label_set_text(menuTitle, "");
  const dd::Screen screen = device.screen();
  // What the carousel animation compares: slots and menu entries slide, a
  // change of screen does not.
  int index = -1;
  switch (screen) {
    case dd::Screen::Offline:
      showStatus(dd::ICON_STATUS_OFFLINE, device.language());
      break;
    case dd::Screen::Switching:
      showStatus(dd::ICON_STATUS_DEVELOP, device.language());
      break;
    case dd::Screen::Loaded:
      showStatus(dd::ICON_STATUS_LOADED, device.language());
      break;
    case dd::Screen::NoPhoto:
      showStatus(dd::ICON_STATUS_NOPHOTO, device.language());
      break;
    case dd::Screen::Slot:
      if (device.slotCount() == 0) {
        showStatus(dd::ICON_STATUS_OFFLINE, device.language());
      } else {
        showSlot(device);
        index = device.index();
      }
      break;
    case dd::Screen::JobMenu:
      showMenu(device, nowMs);
      if (device.serviceConnected() && device.menuCount() > 0) index = 1000 + device.menuIndex();
      break;
    case dd::Screen::TimerNotice:
      showTimerNotice(device);
      break;
  }
  if (index >= 0 && shownIndex >= 0 && index != shownIndex && (index >= 1000) == (shownIndex >= 1000) &&
      device.lastMove() != 0) {
    startSlide(device.lastMove(), index < 1000);
  }
  shownIndex = index;

  // The running time: small in the gap of the ring; in the menu it is shown big.
  char time[12] = "";
  if (device.timerRunning() && screen != dd::Screen::JobMenu && screen != dd::Screen::Offline) {
    dd::formatElapsed(device.timerSeconds(nowMs), time);
  }
  lv_label_set_text(gapTime, time);

  if (hold > 0) {
    lv_anim_delete(ring, setRingOpacity);
    lv_arc_set_angles(ring, static_cast<lv_value_precise_t>(kRingStartDeg),
                      static_cast<lv_value_precise_t>((kRingStartDeg + (hold > kRingSweepDeg ? kRingSweepDeg : hold)) % 360));
    lv_obj_set_style_arc_color(ring, lv_color_white(), LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(ring, LV_OPA_COVER, LV_PART_INDICATOR);
  }
}
