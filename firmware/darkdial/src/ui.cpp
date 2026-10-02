#include "ui.h"

#include <lvgl.h>

#include "core/params.h"
#include "icons.h"

extern "C" {
extern const lv_font_t dd_font_label;
extern const lv_font_t dd_font_value;
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
constexpr uint32_t kColorTrack = 0x26262B;
constexpr uint32_t kColorSelect = 0x8A8A90;
constexpr uint32_t kColorAccent = 0xFF9F0A;
constexpr uint32_t kColorLabel = 0xB8B8BE;
constexpr uint32_t kBootLogoMs = 1500;
constexpr uint32_t kSlideMs = 160;
constexpr int kSlideDistance = 90;

lv_obj_t *ring = nullptr;
lv_obj_t *iconBox = nullptr;
lv_obj_t *icon = nullptr;
lv_obj_t *dot = nullptr;
lv_obj_t *label = nullptr;
lv_obj_t *value = nullptr;
lv_obj_t *logo = nullptr;

void (*tapHandler)() = nullptr;
uint32_t bootMs = 0;
uint32_t shownRevision = UINT32_MAX;
int shownIndex = -1;
bool shownSlotScreen = false;

void onScreenClicked(lv_event_t *) {
  if (tapHandler) tapHandler();
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

/// Icon slides in from the side it was turned to, the ring fades over.
void startSlide(int direction) {
  animate(iconBox, setTranslateX, direction * kSlideDistance, 0, kSlideMs);
  animate(iconBox, setOpacity, LV_OPA_TRANSP, LV_OPA_COVER, kSlideMs);
  animate(ring, setRingOpacity, LV_OPA_TRANSP, LV_OPA_COVER, kSlideMs + 60);
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

void showStatus(uint8_t iconId, uint8_t language) {
  setIcon(iconId);
  lv_obj_set_hidden(dot, true);
  const char *text = "";
  for (const dd::StatusText &status : dd::kStatusText) {
    if (status.icon == iconId) text = language == 0 ? status.de : status.en;
  }
  lv_label_set_text(label, text);
  lv_label_set_text(value, "");
  hideIndicator();
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

void ui_init(void (*onTap)(), uint32_t nowMs) {
  tapHandler = onTap;
  bootMs = nowMs;
  shownRevision = UINT32_MAX;
  shownIndex = -1;
  shownSlotScreen = false;

  lv_obj_t *screen = lv_screen_active();
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
  lv_obj_set_scrollable(screen, false);
  lv_obj_add_event_cb(screen, onScreenClicked, LV_EVENT_CLICKED, nullptr);

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

  logo = lv_image_create(screen);
  lv_image_set_src(logo, &dd_logo);
  lv_obj_center(logo);
}

void ui_update(const dd::Device &device, uint32_t nowMs) {
  if (logo && nowMs - bootMs >= kBootLogoMs) {
    lv_obj_delete(logo);
    logo = nullptr;
  }
  if (device.revision() == shownRevision) return;
  shownRevision = device.revision();

  const dd::Screen screen = device.slotCount() ? device.screen() : dd::Screen::Offline;
  const bool slotScreen = screen == dd::Screen::Slot;
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
      showSlot(device);
      // Slide only when the carousel moved, not when a screen changed.
      if (shownSlotScreen && shownIndex >= 0 && shownIndex != device.index() && device.lastMove() != 0) {
        startSlide(device.lastMove());
      }
      break;
  }
  shownIndex = slotScreen ? device.index() : -1;
  shownSlotScreen = slotScreen;
}
