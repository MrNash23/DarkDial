// State machine of the device: carousel, edit mode, configuration transfer,
// heartbeat. Portable C++; the Dart twin is DeviceModel in
// app/packages/darkdial_core/lib/src/simulator.dart - keep both in sync.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

namespace dd {

enum class Mode : uint8_t { Select, Edit };

/// What the display shows; status screens replace the slot.
enum class Screen : uint8_t {
  Offline,    // no service
  Switching,  // Lightroom is switching to the Develop module
  Loaded,     // configuration received, shown briefly
  NoPhoto,    // no photo selected in Lightroom
  Slot,
};

constexpr uint8_t kStatusLightroom = 1;
constexpr uint8_t kStatusDevelop = 2;
constexpr uint8_t kStatusPhoto = 4;

constexpr uint32_t kHeartbeatTimeoutMs = 5000;
constexpr uint32_t kLoadedNoticeMs = 1200;

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
};

/// Turns raw detents into accelerated ones: slow turning gives single steps,
/// fast turning large ones.
class Accelerator {
 public:
  int apply(int detents, uint32_t nowMs);

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

  /// Knob turned by `detents` (sign = direction).
  void rotate(int detents, uint32_t nowMs);
  /// Knob pressed or display tapped.
  void click();
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

  uint16_t configCrc() const;

 private:
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
  bool loadedNotice_ = false;
  uint32_t loadedAtMs_ = 0;

  // Configuration transfer in progress.
  bool receiving_ = false;
  Slot incoming_[kMaxSlots];
  uint8_t incomingCount_ = 0;
  uint8_t incomingExpected_ = 0;
  uint8_t incomingLanguage_ = 1;
  uint16_t incomingCrc_ = 0xFFFF;

  Accelerator accelerator_;
  uint32_t revision_ = 0;
};

}  // namespace dd
