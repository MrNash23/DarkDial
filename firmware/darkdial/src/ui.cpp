#include "ui.h"

#include <lvgl.h>
#include <math.h>
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
constexpr int kMenuTitleTop = 44;   // page title of the time tracking menu, clear of the ring
constexpr int kInfoTop = 178;       // wrapped help text below the icon
constexpr int kInfoWidth = 250;  // the running time sits in the gap of the ring
// The ring only starts to fill after this part of the long press, so a
// normal click does not flash it.
constexpr float kHoldVisibleFrom = 0.2f;
// Library: five dots for the stars where the icon sits otherwise, the colour
// label as a bar below them, the flag in words below the file name.
constexpr int kStarSize = 26;
constexpr int kStarGap = 14;
constexpr int kStarTop = 100;
constexpr int kColorBarTop = 144;
constexpr int kColorBarWidth = 5 * kStarSize + 4 * kStarGap;
constexpr int kFlagTop = 236;
constexpr uint32_t kLibraryColors[6] = {0, 0xFA3A31, 0xF8D32D, 0x7FE530, 0x5394FC, 0xAE72F9};
constexpr uint32_t kColorRejected = 0xE5484D;
constexpr uint32_t kColorTrack = 0x26262B;
constexpr uint32_t kColorSelect = 0x8A8A90;
constexpr uint32_t kColorAccent = 0xFF9F0A;
constexpr uint32_t kColorLabel = 0xB8B8BE;
constexpr uint32_t kBootLogoMs = 3000;  // the logo at start-up; it also shows while idle
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
lv_obj_t *infoText = nullptr;
// The previous and the next slider, small and dim beside the current one,
// while turning through them.
lv_obj_t *prevIcon = nullptr;
lv_obj_t *nextIcon = nullptr;
constexpr int kNeighborOffset = 96;
constexpr int kNeighborScale = 112;  // 256 = full size; small enough to stay clear of the ring
constexpr lv_opa_t kNeighborOpa = 90;
// The carousel animation: four icons move one place along while it runs –
// the outer neighbour leaves, the centre becomes a neighbour, a neighbour
// becomes the centre, a new neighbour comes in. The real objects (iconBox and
// the neighbours) are hidden meanwhile and take over at the end.
lv_obj_t *carousel[4] = {};
bool carouselRunning = false;
int carouselDirection = 0;
constexpr uint32_t kCarouselMs = 280;
constexpr int kOuterOffset = 130;  // where a neighbour comes from or goes to
constexpr int kOuterScale = 64;
lv_obj_t *stars[5] = {};
lv_obj_t *colorBar = nullptr;
lv_obj_t *flagText = nullptr;
lv_obj_t *logo = nullptr;
bool logoShown = true;

// Everything but the ring and the logo is placed through this table, so the
// whole picture can be turned for a device that does not stand upright: each
// object is moved to its turned position and turned around its own centre.
// Only small objects are transformed that way, which keeps drawing fast; at
// 0 degrees nothing is transformed at all.
struct Placed {
  lv_obj_t *object;
  int x;        // centre, from the centre of the display
  int y;        // top edge from the top, or bottom edge from the bottom
  bool bottom;
};
constexpr int kMaxPlaced = 24;
Placed placed[kMaxPlaced];
int placedCount = 0;
float turnCos = 1;
float turnSin = 0;

void place(lv_obj_t *object, int x, int y, bool bottom = false) {
  if (placedCount < kMaxPlaced) placed[placedCount++] = {object, x, y, bottom};
}

/// Puts every object where it belongs for a picture turned by `degrees`
/// clockwise. Sizes follow the texts, so this runs after every change.
void layout(int degrees) {
  static int applied = -1;
  const bool turn = degrees != applied;
  applied = degrees;
  lv_obj_update_layout(lv_screen_active());
  const float radians = static_cast<float>(degrees) * 3.14159265f / 180.0f;
  turnCos = cosf(radians);
  turnSin = sinf(radians);
  for (int i = 0; i < placedCount; i++) {
    const Placed &p = placed[i];
    const int width = lv_obj_get_width(p.object);
    const int height = lv_obj_get_height(p.object);
    const float cx = static_cast<float>(p.x);
    const float cy = (p.bottom ? kDisplaySize - p.y - height / 2.0f : p.y + height / 2.0f) - kDisplaySize / 2.0f;
    lv_obj_align(p.object, LV_ALIGN_CENTER, static_cast<int32_t>(lroundf(cx * turnCos - cy * turnSin)),
                 static_cast<int32_t>(lroundf(cx * turnSin + cy * turnCos)));
    // Setting a style redraws the object, so only when something changes.
    if (degrees != 0) {
      lv_obj_set_style_transform_pivot_x(p.object, width / 2, 0);
      lv_obj_set_style_transform_pivot_y(p.object, height / 2, 0);
    }
    if (turn) lv_obj_set_style_transform_rotation(p.object, degrees * 10, 0);
  }
  if (turn) {
    lv_arc_set_rotation(ring, degrees);
    lv_image_set_rotation(logo, degrees * 10);
  }
}

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

// The slide runs along the turned horizontal.
void setTranslateX(void *object, int32_t x) {
  lv_obj_set_style_translate_x(static_cast<lv_obj_t *>(object), static_cast<int32_t>(lroundf(x * turnCos)), 0);
  lv_obj_set_style_translate_y(static_cast<lv_obj_t *>(object), static_cast<int32_t>(lroundf(x * turnSin)), 0);
}

void setOpacity(void *object, int32_t opacity) {
  lv_obj_set_style_opa(static_cast<lv_obj_t *>(object), static_cast<lv_opa_t>(opacity), 0);
}

// Image opacity blends pixel by pixel; object opacity would draw through a
// layer and show the corners of the scaled icon's box.
void setImageOpacity(void *object, int32_t opacity) {
  lv_obj_set_style_image_opa(static_cast<lv_obj_t *>(object), static_cast<lv_opa_t>(opacity), 0);
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
  animate(prevIcon, setImageOpacity, LV_OPA_TRANSP, kNeighborOpa, kSlideMs + 80);
  animate(nextIcon, setImageOpacity, LV_OPA_TRANSP, kNeighborOpa, kSlideMs + 80);
  if (withRing) animate(ring, setRingOpacity, LV_OPA_TRANSP, LV_OPA_COVER, kSlideMs + 60);
}

/// One icon of the carousel at `t` (0 … 1) between two places.
void carouselStep(lv_obj_t *image, float t, int x0, int x1, int s0, int s1, int o0, int o1) {
  const float x = x0 + (x1 - x0) * t;
  lv_obj_set_style_translate_x(image, static_cast<int32_t>(lroundf(x * turnCos)), 0);
  lv_obj_set_style_translate_y(image, static_cast<int32_t>(lroundf(x * turnSin)), 0);
  lv_image_set_scale(image, static_cast<uint32_t>(lroundf(s0 + (s1 - s0) * t)));
  lv_obj_set_style_image_opa(image, static_cast<lv_opa_t>(lroundf(o0 + (o1 - o0) * t)), 0);
}

void setCarousel(void *, int32_t progress) {
  const float t = progress / 1024.0f;
  const int d = carouselDirection;  // +1: turned to the next slider, everything moves left
  carouselStep(carousel[0], t, -d * kNeighborOffset, -d * kOuterOffset, kNeighborScale, kOuterScale, kNeighborOpa, 0);
  carouselStep(carousel[1], t, 0, -d * kNeighborOffset, 256, kNeighborScale, LV_OPA_COVER, kNeighborOpa);
  carouselStep(carousel[2], t, d * kNeighborOffset, 0, kNeighborScale, 256, kNeighborOpa, LV_OPA_COVER);
  carouselStep(carousel[3], t, d * kOuterOffset, d * kNeighborOffset, kOuterScale, kNeighborScale, 0, kNeighborOpa);
}

// The helper images stay until the next update has shown the real objects,
// so no frame is drawn without an icon.
void finishCarousel(lv_anim_t *) {
  carouselRunning = false;
  shownRevision = UINT32_MAX;
}

/// Starts the carousel from the slot shown to the one now selected.
/// `icons`: the leaving neighbour, the old centre, the new centre, the coming
/// neighbour.
void startCarousel(int direction, const uint8_t icons[4]) {
  lv_anim_delete(nullptr, setCarousel);
  carouselDirection = direction;
  carouselRunning = true;
  for (int i = 0; i < 4; i++) {
    const lv_image_dsc_t *source = icons[i] < DD_ICON_TABLE_SIZE ? dd_icons[icons[i]] : nullptr;
    lv_obj_set_hidden(carousel[i], source == nullptr);
    if (source) lv_image_set_src(carousel[i], source);
  }
  lv_obj_set_hidden(iconBox, true);
  lv_obj_set_hidden(prevIcon, true);
  lv_obj_set_hidden(nextIcon, true);
  setCarousel(nullptr, 0);
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_exec_cb(&a, setCarousel);
  lv_anim_set_values(&a, 0, 1024);
  lv_anim_set_duration(&a, kCarouselMs);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_set_completed_cb(&a, finishCarousel);
  lv_anim_start(&a);
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
  if (item.info) {
    // The help line: clients are created in the desktop app.
    showMessage(item.icon, "");
    lv_label_set_text(infoText, timerText(dd::TEXT_NOCLIENT, device.language()));
  }
  char time[12] = "";
  if (item.running && device.timerRunning()) dd::formatElapsed(device.timerSeconds(nowMs), time);
  char text[dd::kMaxLabelBytes + 4];
  // "»" (Latin-1) marks a line that leads to another page.
  snprintf(text, sizeof(text), item.submenu ? "%s \xC2\xBB" : "%s", item.label);
  if (!item.info) showMessage(item.icon, text, time);
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

/// The Library: stars, colour label, file name and flag of the selected photo.
void showLibrary(const dd::Device &device) {
  showMessage(dd::ICON_COUNT, device.libraryName());  // no icon
  lv_label_set_text(menuTitle, timerText(dd::TEXT_LIBRARY, device.language()));
  for (int i = 0; i < 5; i++) {
    lv_obj_set_style_bg_color(stars[i], lv_color_hex(i < device.libraryRating() ? kColorAccent : kColorTrack), 0);
    lv_obj_set_hidden(stars[i], false);
  }
  if (device.libraryColor() >= 1 && device.libraryColor() <= 5) {
    lv_obj_set_style_bg_color(colorBar, lv_color_hex(kLibraryColors[device.libraryColor()]), 0);
    lv_obj_set_hidden(colorBar, false);
  }
  if (device.libraryPicked()) {
    lv_obj_set_style_text_color(flagText, lv_color_white(), 0);
    lv_label_set_text(flagText, timerText(dd::TEXT_PICKED, device.language()));
  } else if (device.libraryRejected()) {
    lv_obj_set_style_text_color(flagText, lv_color_hex(kColorRejected), 0);
    lv_label_set_text(flagText, timerText(dd::TEXT_REJECTED, device.language()));
  }
}

/// The picture is being turned with the knob: the angle, a mark on the ring
/// where "up" is, and what to do.
void showRotate(const dd::Device &device) {
  char angle[8];
  snprintf(angle, sizeof(angle), "%u", static_cast<unsigned>(device.displayAngle()));
  showMessage(dd::ICON_COUNT, "", angle);  // no icon
  lv_label_set_text(menuTitle, timerText(dd::TEXT_ROTATE, device.language()));
  lv_label_set_text(infoText, timerText(dd::TEXT_ROTATEHINT, device.language()));
  lv_arc_set_angles(ring, static_cast<lv_value_precise_t>(kRingTopDeg - 8), static_cast<lv_value_precise_t>(kRingTopDeg + 8));
  lv_obj_set_style_arc_color(ring, lv_color_hex(kColorAccent), LV_PART_INDICATOR);
  lv_obj_set_style_arc_opa(ring, LV_OPA_COVER, LV_PART_INDICATOR);
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

  lv_obj_set_hidden(iconBox, carouselRunning);
  // Turning through the sliders: the neighbours on either side.
  if (device.mode() == dd::Mode::Select && device.slotCount() >= 2 && !carouselRunning) {
    const uint8_t count = device.slotCount();
    const uint8_t next = static_cast<uint8_t>((device.index() + 1) % count);
    const uint8_t prev = static_cast<uint8_t>((device.index() + count - 1) % count);
    auto show = [](lv_obj_t *image, uint8_t iconId) {
      const lv_image_dsc_t *source = iconId < DD_ICON_TABLE_SIZE ? dd_icons[iconId] : nullptr;
      if (!source) return;
      lv_image_set_src(image, source);
      lv_obj_set_hidden(image, false);
    };
    show(nextIcon, device.slot(next).iconId);
    if (count >= 3) show(prevIcon, device.slot(prev).iconId);
  }

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
  logoShown = true;
  placedCount = 0;

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
  place(iconBox, 0, kIconTop);
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
  place(label, 0, kLabelTop);
  lv_label_set_text(label, "");

  value = lv_label_create(screen);
  lv_obj_set_style_text_font(value, &dd_font_value, 0);
  lv_obj_set_style_text_color(value, lv_color_white(), 0);
  place(value, 0, kValueTop);
  lv_label_set_text(value, "");

  gapTime = lv_label_create(screen);
  lv_obj_set_style_text_font(gapTime, &dd_font_small, 0);
  lv_obj_set_style_text_color(gapTime, lv_color_hex(kColorLabel), 0);
  place(gapTime, 0, kGapTimeBottom, true);
  lv_label_set_text(gapTime, "");

  menuTitle = lv_label_create(screen);
  lv_obj_set_style_text_font(menuTitle, &dd_font_small, 0);
  lv_obj_set_style_text_color(menuTitle, lv_color_hex(kColorSelect), 0);
  place(menuTitle, 0, kMenuTitleTop);
  lv_label_set_text(menuTitle, "");

  infoText = lv_label_create(screen);
  lv_obj_set_style_text_font(infoText, &dd_font_small, 0);
  lv_obj_set_style_text_color(infoText, lv_color_hex(kColorLabel), 0);
  lv_obj_set_style_text_align(infoText, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(infoText, kInfoWidth);
  lv_label_set_long_mode(infoText, LV_LABEL_LONG_MODE_WRAP);
  place(infoText, 0, kInfoTop);
  lv_label_set_text(infoText, "");

  lv_obj_t **neighbors[2] = {&prevIcon, &nextIcon};
  for (lv_obj_t **neighbor : neighbors) {
    *neighbor = lv_image_create(screen);
    lv_image_set_scale(*neighbor, kNeighborScale);
    lv_obj_set_style_image_opa(*neighbor, kNeighborOpa, 0);
    lv_obj_set_clickable(*neighbor, false);
    lv_obj_set_hidden(*neighbor, true);
  }
  place(prevIcon, -kNeighborOffset, kIconTop);
  place(nextIcon, kNeighborOffset, kIconTop);
  for (lv_obj_t *&image : carousel) {
    image = lv_image_create(screen);
    lv_image_set_antialias(image, false);  // cheaper while moving; not visible at that speed
    lv_obj_set_clickable(image, false);
    lv_obj_set_hidden(image, true);
    place(image, 0, kIconTop);
  }

  for (int i = 0; i < 5; i++) {
    stars[i] = lv_obj_create(screen);
    lv_obj_remove_style_all(stars[i]);
    lv_obj_set_size(stars[i], kStarSize, kStarSize);
    place(stars[i], (i - 2) * (kStarSize + kStarGap), kStarTop);
    lv_obj_set_style_radius(stars[i], LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_opa(stars[i], LV_OPA_COVER, 0);
    lv_obj_set_clickable(stars[i], false);
    lv_obj_set_hidden(stars[i], true);
  }
  colorBar = lv_obj_create(screen);
  lv_obj_remove_style_all(colorBar);
  lv_obj_set_size(colorBar, kColorBarWidth, 8);
  place(colorBar, 0, kColorBarTop);
  lv_obj_set_style_radius(colorBar, 4, 0);
  lv_obj_set_style_bg_opa(colorBar, LV_OPA_COVER, 0);
  lv_obj_set_clickable(colorBar, false);
  lv_obj_set_hidden(colorBar, true);

  flagText = lv_label_create(screen);
  lv_obj_set_style_text_font(flagText, &dd_font_label, 0);
  place(flagText, 0, kFlagTop);
  lv_label_set_text(flagText, "");

  // The logo is created last so it covers everything while it is shown.
  logo = lv_image_create(screen);
  lv_image_set_src(logo, &dd_logo);
  lv_obj_center(logo);
  layout(0);
}

void ui_update(const dd::Device &device, uint32_t nowMs) {
  // The logo covers everything at start-up and whenever the device is idle.
  const bool showLogo = nowMs - bootMs < kBootLogoMs || device.idle();
  if (showLogo != logoShown) {
    logoShown = showLogo;
    lv_obj_set_hidden(logo, !showLogo);
  }
  // The ring fills while the knob is held towards the long press.
  const float progress = device.holdProgress(nowMs);
  const int hold = progress > kHoldVisibleFrom
                       ? 1 + static_cast<int>((progress - kHoldVisibleFrom) / (1 - kHoldVisibleFrom) * kRingSweepDeg)
                       : 0;
  if (device.revision() == shownRevision && hold == shownHold) return;
  shownRevision = device.revision();
  shownHold = hold;
  if (!carouselRunning) {
    for (lv_obj_t *image : carousel) lv_obj_set_hidden(image, true);
  }

  lv_obj_set_style_text_color(label, lv_color_hex(kColorLabel), 0);
  lv_label_set_text(menuTitle, "");
  lv_label_set_text(infoText, "");
  lv_label_set_text(flagText, "");
  for (lv_obj_t *star : stars) lv_obj_set_hidden(star, true);
  lv_obj_set_hidden(prevIcon, true);
  lv_obj_set_hidden(nextIcon, true);
  lv_obj_set_hidden(colorBar, true);
  const dd::Screen screen = device.screen();
  // What the carousel animation compares: slots and menu entries slide, a
  // change of screen does not.
  int index = -1;
  switch (screen) {
    case dd::Screen::Idle:
      break;  // the logo covers the display; what is underneath is redrawn on wake-up
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
    case dd::Screen::Library:
      showLibrary(device);
      break;
    case dd::Screen::Rotate:
      showRotate(device);
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
    const int count = device.slotCount();
    if (index < 1000 && device.mode() == dd::Mode::Select && count >= 3 && shownIndex < count) {
      // Sliders: the carousel moves one place along.
      const int d = device.lastMove();
      const uint8_t icons[4] = {
          device.slot(static_cast<uint8_t>((shownIndex - d + count) % count)).iconId,
          device.slot(static_cast<uint8_t>(shownIndex)).iconId,
          device.slot(static_cast<uint8_t>(index)).iconId,
          device.slot(static_cast<uint8_t>((index + d + count) % count)).iconId,
      };
      // Ring, name and value change at once: fading them on every detent
      // blinks when the knob keeps turning.
      startCarousel(d, icons);
      lv_obj_set_hidden(iconBox, true);
    } else {
      startSlide(device.lastMove(), index < 1000);
    }
  }
  shownIndex = index;

  // The running time: small in the gap of the ring; in the menu it is shown big.
  char time[12] = "";
  if (device.timerRunning() && screen != dd::Screen::JobMenu && screen != dd::Screen::Offline) {
    dd::formatElapsed(device.timerSeconds(nowMs), time);
  }
  lv_label_set_text(gapTime, time);
  // The picture is drawn upright; a turned device gets it turned as a whole
  // on the way to the display (board::setDisplayAngle, or the snapshot tool).
  layout(0);

  if (hold > 0) {
    lv_anim_delete(ring, setRingOpacity);
    lv_arc_set_angles(ring, static_cast<lv_value_precise_t>(kRingStartDeg),
                      static_cast<lv_value_precise_t>((kRingStartDeg + (hold > kRingSweepDeg ? kRingSweepDeg : hold)) % 360));
    lv_obj_set_style_arc_color(ring, lv_color_white(), LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(ring, LV_OPA_COVER, LV_PART_INDICATOR);
  }
}
