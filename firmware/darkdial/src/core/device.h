// State machine of the device: carousel, edit mode, browsing in the Library,
// configuration transfer, heartbeat, and the time tracking menu behind the
// long press. Portable C++;
// the Dart twin is DeviceModel in
// app/packages/darkdial_core/lib/src/simulator.dart - keep both in sync.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

namespace dd {

enum class Mode : uint8_t { Select, Edit };

/// What the display shows; status screens replace the slot.
enum class Screen : uint8_t {
  Idle,       // nobody touched the device for a while: the logo
  Offline,    // no service
  Switching,  // Lightroom is switching to the Develop module
  Loaded,     // configuration received, shown briefly
  NoPhoto,    // no photo selected in Lightroom
  Slot,
  JobMenu,      // time tracking menu, opened by a long press
  TimerNotice,  // "started" / "stopped" / an error text, shown briefly
  Library,      // Lightroom shows the Library: the knob browses, taps rate
  Rotate,       // the knob turns the picture, started from the app
};

constexpr uint8_t kStatusLightroom = 1;
constexpr uint8_t kStatusDevelop = 2;
constexpr uint8_t kStatusPhoto = 4;

constexpr uint32_t kHeartbeatTimeoutMs = 5000;
constexpr uint32_t kLoadedNoticeMs = 1200;
constexpr uint32_t kLongPressMs = 500;
// The knob is the display: pressing it puts a finger on the glass. Touch
// input is ignored while the knob is down and this long after it moved.
constexpr uint32_t kTouchGuardMs = 500;
constexpr uint32_t kTimerNoticeMs = 1200;
constexpr uint32_t kDoubleTapMs = 350;
// A finger that is about to press the knob often taps the glass first. A tap
// therefore only counts once this time has passed without the knob going
// down; where a double tap is possible, that wait is longer anyway.
constexpr uint32_t kTapConfirmMs = 200;
// The menu closes by itself after this long without input.
constexpr uint32_t kMenuTimeoutMs = 20000;
// One detent turns the picture by this many degrees while it is adjusted.
constexpr int kRotationStepDegrees = 5;
// Without knob or touch input for this long the display shows the logo.
constexpr uint32_t kIdleMs = 180000;

/// Writes the time for the display: mm:ss below one hour, then h:mm.
/// `out` needs 12 bytes.
void formatElapsed(uint32_t seconds, char *out);

// Stored configuration: count, language, then per slot a length byte and the
// ConfigSlot payload.
constexpr size_t kMaxStoredConfigBytes = 2 + kMaxSlots * (1 + kMaxPayloadBytes);

/// What the device core needs from its surroundings.
class Host {
 public:
  virtual ~Host() = default;
  /// Sends one complete MIDI message to the service.
  virtual void send(const uint8_t *bytes, size_t n) = 0;
  /// Persists the configuration (see Device::loadStored).
  virtual void saveConfig(const uint8_t *blob, size_t n) = 0;
  /// Persists the angle the picture is turned by (see Device::setRotation).
  virtual void saveRotation(uint16_t /*degrees*/) {}
};

/// How fast the knob turns: 0 slow, 1 … 3 faster and faster. Older services
/// get accelerated detents (apply); from protocol 1.5 the service gets the
/// speed with the raw detents and decides itself (speed).
class Accelerator {
 public:
  int apply(int detents, uint32_t nowMs);
  int speed(uint32_t nowMs);

 private:
  uint32_t lastMs_ = 0;
  bool primed_ = false;
};

class Device {
 public:
  Device(Host &host, uint8_t fwMajor, uint8_t fwMinor, uint8_t fwPatch, const uint8_t serial[6]);

  /// Loads a configuration written by Host::saveConfig. False (and defaults
  /// stay) if the blob is damaged.
  bool loadStored(const uint8_t *blob, size_t n);

  /// Sets the stored angle of the picture at start-up: 0 … 359 degrees
  /// clockwise, for a device that does not stand upright.
  void setRotation(uint16_t degrees);
  /// The angle to draw with: the stored one, or the one being tried out.
  uint16_t displayAngle() const { return adjusting_ ? adjustAngle_ : rotation_; }
  /// True while the knob turns the picture.
  bool adjustingRotation() const { return adjusting_; }

  /// Knob turned by `detents` (sign = direction).
  void rotate(int detents, uint32_t nowMs);
  /// A click on what is shown: selects a slot or leaves it, chooses a menu
  /// line. Comes from a tap on the display, and from the knob wherever the
  /// knob does not switch the module.
  void click();
  /// The display was tapped. A tap is a click; in edit mode two taps within
  /// kDoubleTapMs reset the slot to its default instead; in the Library a tap
  /// and a double tap are the two actions chosen in the app. No tap acts at
  /// once: it waits (in tick) for a second tap where there is a double tap,
  /// otherwise kTapConfirmMs, and is dropped if the knob goes down meanwhile.
  /// Returns false if the tap was ignored because it came with a press of
  /// the knob.
  bool tap(uint32_t nowMs);
  /// The display was touched and held: in edit mode, reset the slot to its
  /// default. Returns false if ignored.
  bool longTouch(uint32_t nowMs);
  /// The knob went down / came up. A click is only decided on release, and
  /// only if the long press has not fired, so the two can never overlap.
  /// While the service offers the Library mode, the click switches between
  /// Library and Develop and slots are selected by tapping the display.
  void buttonDown(uint32_t nowMs);
  void buttonUp(uint32_t nowMs);
  /// True while the logo is shown because nobody used knob or touch for
  /// kIdleMs. The next input only brings the display back; it is not acted on.
  bool idle() const { return idle_; }
  /// 0 … 1 while the knob is held towards a long press, else 0.
  float holdProgress(uint32_t nowMs) const;
  /// One complete MIDI message from the service.
  void onMessage(const uint8_t *bytes, size_t n, uint32_t nowMs);
  /// Call regularly; handles the heartbeat timeout and notices.
  void tick(uint32_t nowMs);

  // State for the UI ---------------------------------------------------------
  Screen screen() const;
  Mode mode() const { return mode_; }
  uint8_t slotCount() const { return slotCount_; }
  uint8_t index() const { return index_; }
  const Slot &slot(uint8_t i) const { return slots_[i]; }
  const SlotValue &value(uint8_t i) const { return values_[i]; }
  bool serviceConnected() const { return serviceConnected_; }
  bool lightroomConnected() const { return (statusFlags_ & kStatusLightroom) != 0; }
  bool photoSelected() const { return (statusFlags_ & kStatusPhoto) != 0; }
  /// 0 = German, 1 = English, for the status texts.
  uint8_t language() const { return language_; }
  /// Changes whenever something visible changed.
  uint32_t revision() const { return revision_; }
  /// Direction of the last carousel move: -1, 0 or +1, for the slide animation.
  int lastMove() const { return lastMove_; }

  // Library --------------------------------------------------------------------
  /// True while Lightroom shows the Library and the knob browses the photos.
  bool libraryActive() const { return serviceConnected_ && (libraryFlags_ & kLibraryActive) != 0; }
  bool libraryPicked() const { return (libraryFlags_ & kLibraryPicked) != 0; }
  bool libraryRejected() const { return (libraryFlags_ & kLibraryRejected) != 0; }
  uint8_t libraryRating() const { return libraryRating_; }
  /// 0 none, 1 red, 2 yellow, 3 green, 4 blue, 5 purple.
  uint8_t libraryColor() const { return libraryColor_; }
  const char *libraryName() const { return libraryName_; }

  // Time tracking -------------------------------------------------------------
  // The menu is a page sent by the service; the device shows one line at a
  // time and reports which one was chosen.
  bool menuOpen() const { return menuOpen_; }
  uint8_t menuCount() const { return menuCount_; }
  uint8_t menuIndex() const { return menuIndex_; }
  const MenuItem &menuItem(uint8_t i) const { return menuItems_[i]; }
  const char *menuTitle() const { return menuTitle_; }
  bool timerRunning() const { return timerRunning_; }
  uint32_t timerJobId() const { return timerJobId_; }
  const char *timerLabel() const { return timerLabel_; }
  /// Seconds of the running entry, counted on locally since the last TimerState.
  uint32_t timerSeconds(uint32_t nowMs) const;
  /// TimerNotice: 0 started, 1 stopped, otherwise an error with noticeText().
  uint8_t noticeCode() const { return noticeCode_; }
  const char *noticeText() const { return noticeText_; }

  uint16_t configCrc() const;

 private:
  void longPress(uint32_t nowMs);
  void endRotation(bool save);
  void reportRotation();
  void knobClick(uint32_t nowMs);
  bool doubleTapPossible() const;
  void singleTap();
  void libraryAction(uint8_t action);
  void menuAction(uint32_t nowMs);
  void closeMenu();
  bool touchAllowed(uint32_t nowMs) const;
  bool wake(uint32_t nowMs);
  void resetSlot();
  void loadDefaults();
  void changed() { revision_++; }
  void finishConfig(const Message &message, uint32_t nowMs);
  void store();

  Host &host_;
  uint8_t fw_[3];
  uint8_t serial_[6];

  Slot slots_[kMaxSlots];
  SlotValue values_[kMaxSlots];
  uint8_t slotCount_ = 0;
  uint8_t index_ = 0;
  uint8_t language_ = 1;
  Mode mode_ = Mode::Select;
  int lastMove_ = 0;

  uint8_t statusFlags_ = 0;
  uint8_t notice_ = 0;
  bool serviceConnected_ = false;
  uint32_t lastStatusMs_ = 0;
  uint8_t serviceMinor_ = 0;
  bool loadedNotice_ = false;
  uint32_t loadedAtMs_ = 0;

  // Configuration transfer in progress.
  bool receiving_ = false;
  Slot incoming_[kMaxSlots];
  uint8_t incomingCount_ = 0;
  uint8_t incomingExpected_ = 0;
  uint8_t incomingLanguage_ = 1;
  uint16_t incomingCrc_ = 0xFFFF;

  // Display taps.
  bool tapPending_ = false;
  uint32_t tapAtMs_ = 0;
  uint32_t tapWaitMs_ = 0;

  // Rotation of the picture.
  uint16_t rotation_ = 0;
  uint16_t adjustAngle_ = 0;
  bool adjusting_ = false;

  // Library.
  uint8_t libraryFlags_ = 0;
  uint8_t libraryRating_ = 0;
  uint8_t libraryColor_ = 0;
  char libraryName_[kMaxLabelBytes + 1] = {0};

  // Idle logo.
  bool idle_ = false;
  uint32_t lastInputMs_ = 0;
  bool swallowPress_ = false;
  bool knobDown_ = false;  // physically held, whether or not the press counts

  // Knob.
  bool pressed_ = false;
  bool longFired_ = false;
  uint32_t pressedAtMs_ = 0;
  bool knobUsed_ = false;
  uint32_t knobMovedAtMs_ = 0;

  // Time tracking.
  bool menuOpen_ = false;
  uint8_t menuIndex_ = 0;
  uint8_t menuPage_ = 0;
  uint32_t menuActivityMs_ = 0;
  MenuItem menuItems_[kMaxMenuItems];
  uint8_t menuCount_ = 0;
  char menuTitle_[kMaxLabelBytes + 1] = {0};
  // Page being received.
  bool receivingMenu_ = false;
  MenuItem incomingItems_[kMaxMenuItems];
  uint8_t incomingItemCount_ = 0;
  uint8_t incomingItemExpected_ = 0;
  uint8_t incomingPage_ = 0;
  uint8_t incomingSelected_ = 0;
  char incomingTitle_[kMaxLabelBytes + 1] = {0};
  uint32_t lastNowMs_ = 0;
  bool timerRunning_ = false;
  uint32_t timerJobId_ = 0;
  uint32_t timerBaseSeconds_ = 0;
  uint32_t timerBaseMs_ = 0;
  uint32_t timerShownSeconds_ = 0;
  char timerLabel_[kMaxLabelBytes + 1] = {0};
  bool timerNotice_ = false;
  uint32_t timerNoticeAtMs_ = 0;
  uint8_t noticeCode_ = 0;
  char noticeText_[kMaxLabelBytes + 1] = {0};

  Accelerator accelerator_;
  uint32_t revision_ = 0;
};

}  // namespace dd
