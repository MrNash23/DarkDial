#include "device.h"

#include <stdio.h>
#include <string.h>

#include "params.h"

namespace dd {

int Accelerator::apply(int detents, uint32_t nowMs) {
  const uint32_t gap = nowMs - lastMs_;
  lastMs_ = nowMs;
  if (!primed_) {
    primed_ = true;
    return detents;
  }
  // Time between two detents decides the factor.
  int factor = 1;
  if (gap < 15) {
    factor = 8;
  } else if (gap < 30) {
    factor = 4;
  } else if (gap < 60) {
    factor = 2;
  }
  return detents * factor;
}

void formatElapsed(uint32_t seconds, char *out) {
  if (seconds < 3600) {
    snprintf(out, 12, "%02u:%02u", static_cast<unsigned>(seconds / 60), static_cast<unsigned>(seconds % 60));
  } else {
    snprintf(out, 12, "%u:%02u", static_cast<unsigned>(seconds / 3600), static_cast<unsigned>(seconds / 60 % 60));
  }
}

Device::Device(Host &host, uint8_t fwMajor, uint8_t fwMinor, uint8_t fwPatch, const uint8_t serial[6])
    : host_(host), fw_{fwMajor, fwMinor, fwPatch} {
  memcpy(serial_, serial, 6);
  loadDefaults();
}

void Device::loadDefaults() {
  slotCount_ = kDefaultSlotCount;
  for (uint8_t i = 0; i < slotCount_; i++) {
    Slot &slot = slots_[i];
    slot = Slot();
    slot.paramId = kDefaultSlots[i].paramId;
    slot.iconId = kDefaultSlots[i].iconId;
    slot.bipolar = kDefaultSlots[i].bipolar;
    strncpy(slot.label, kDefaultSlots[i].label, kMaxLabelBytes);
    values_[i] = SlotValue();
  }
  language_ = 1;
  index_ = 0;
}

bool Device::loadStored(const uint8_t *blob, size_t n) {
  if (n < 2 || blob[0] < 1 || blob[0] > kMaxSlots) return false;
  const uint8_t count = blob[0];
  static Slot parsed[kMaxSlots];
  size_t at = 2;
  for (uint8_t i = 0; i < count; i++) {
    if (at >= n) return false;
    const size_t length = blob[at++];
    uint8_t index = 0;
    if (at + length > n || !parseSlotPayload(blob + at, length, index, parsed[i]) || index != i) return false;
    at += length;
  }
  for (uint8_t i = 0; i < count; i++) {
    slots_[i] = parsed[i];
    values_[i] = SlotValue();
  }
  slotCount_ = count;
  language_ = blob[1] ? 1 : 0;
  index_ = 0;
  changed();
  return true;
}

void Device::store() {
  static uint8_t blob[kMaxStoredConfigBytes];
  size_t at = 0;
  blob[at++] = slotCount_;
  blob[at++] = language_;
  for (uint8_t i = 0; i < slotCount_; i++) {
    const size_t length = writeSlotPayload(i, slots_[i], blob + at + 1);
    blob[at] = static_cast<uint8_t>(length);
    at += 1 + length;
  }
  host_.saveConfig(blob, at);
}

uint16_t Device::configCrc() const {
  uint16_t crc = 0xFFFF;
  uint8_t payload[kMaxPayloadBytes];
  for (uint8_t i = 0; i < slotCount_; i++) {
    crc = crc16(payload, writeSlotPayload(i, slots_[i], payload), crc);
  }
  return crc;
}

Screen Device::screen() const {
  if (idle_) return Screen::Idle;
  if (menuOpen_) return Screen::JobMenu;
  if (timerNotice_) return Screen::TimerNotice;
  if (!serviceConnected_) return Screen::Offline;
  if (notice_ == 1) return Screen::Switching;
  if (loadedNotice_) return Screen::Loaded;
  if (lightroomConnected() && !photoSelected()) return Screen::NoPhoto;
  return Screen::Slot;
}

uint32_t Device::timerSeconds(uint32_t nowMs) const {
  if (!timerRunning_) return 0;
  return timerBaseSeconds_ + (nowMs - timerBaseMs_) / 1000;
}

/// Notes an input. If the logo was showing, the display comes back and the
/// input is used up by that: returns true, and the caller does nothing else.
bool Device::wake(uint32_t nowMs) {
  lastInputMs_ = nowMs;
  if (!idle_) return false;
  idle_ = false;
  changed();
  return true;
}

bool Device::touchAllowed(uint32_t nowMs) const {
  if (knobDown_) return false;
  return !knobUsed_ || nowMs - knobMovedAtMs_ >= kTouchGuardMs;
}

void Device::resetSlot() {
  uint8_t out[kMaxSysexBytes];
  host_.send(out, buildSlotReset(out, index_));
}

bool Device::tap(uint32_t nowMs) {
  lastNowMs_ = nowMs;
  if (!touchAllowed(nowMs)) return false;
  if (wake(nowMs)) return true;
  if (menuOpen_ || mode_ != Mode::Edit || slotCount_ == 0) {
    tapPending_ = false;
    click();
    return true;
  }
  if (tapPending_ && nowMs - tapAtMs_ <= kDoubleTapMs) {
    tapPending_ = false;
    resetSlot();
    return true;
  }
  tapPending_ = true;
  tapAtMs_ = nowMs;
  return true;
}

bool Device::longTouch(uint32_t nowMs) {
  if (!touchAllowed(nowMs)) return false;
  if (wake(nowMs)) return true;
  if (menuOpen_ || mode_ != Mode::Edit || slotCount_ == 0) return false;
  tapPending_ = false;
  resetSlot();
  return true;
}

void Device::buttonDown(uint32_t nowMs) {
  knobDown_ = true;
  knobUsed_ = true;
  knobMovedAtMs_ = nowMs;
  // A press that brings the display back is neither a click nor a long press.
  swallowPress_ = wake(nowMs);
  if (swallowPress_) return;
  pressed_ = true;
  longFired_ = false;
  pressedAtMs_ = nowMs;
  tapPending_ = false;  // a tap that came with this press is not a tap
}

void Device::buttonUp(uint32_t nowMs) {
  lastNowMs_ = nowMs;
  knobMovedAtMs_ = nowMs;
  lastInputMs_ = nowMs;
  knobDown_ = false;
  if (swallowPress_) {
    swallowPress_ = false;
    return;
  }
  if (pressed_ && !longFired_) click();
  pressed_ = false;
}

float Device::holdProgress(uint32_t nowMs) const {
  if (!pressed_ || longFired_) return 0;
  const uint32_t held = nowMs - pressedAtMs_;
  return held >= kLongPressMs ? 1.0f : static_cast<float>(held) / kLongPressMs;
}

void Device::closeMenu() {
  menuOpen_ = false;
  uint8_t out[kMaxSysexBytes];
  host_.send(out, buildMenuClosed(out));
  changed();
}

/// Opens the time tracking menu from any state, or closes it without change.
void Device::longPress(uint32_t nowMs) {
  if (menuOpen_) {
    closeMenu();
    return;
  }
  menuOpen_ = true;
  menuIndex_ = 0;
  menuCount_ = 0;  // the page comes from the service
  menuTitle_[0] = 0;
  menuActivityMs_ = nowMs;
  timerNotice_ = false;
  lastMove_ = 0;
  uint8_t out[kMaxSysexBytes];
  host_.send(out, buildMenuOpen(out));
  changed();
}

/// Click in the menu. What a line does is decided by the service, which
/// answers with another page or with a result; only "close" is handled here.
void Device::menuAction(uint32_t nowMs) {
  if (!serviceConnected_ || menuCount_ == 0) return;
  menuActivityMs_ = nowMs;
  if (menuItems_[menuIndex_].closes) {
    closeMenu();
    return;
  }
  uint8_t out[kMaxSysexBytes];
  host_.send(out, buildMenuSelect(out, menuPage_, menuIndex_));
}

void Device::rotate(int detents, uint32_t nowMs) {
  if (detents == 0) return;
  if (wake(nowMs)) return;
  if (menuOpen_) {
    menuActivityMs_ = nowMs;
    if (menuCount_ == 0) return;
    int next = (static_cast<int>(menuIndex_) + detents) % menuCount_;
    if (next < 0) next += menuCount_;
    menuIndex_ = static_cast<uint8_t>(next);
    lastMove_ = detents > 0 ? 1 : -1;
    changed();
    return;
  }
  if (slotCount_ == 0) return;
  uint8_t out[kMaxSysexBytes];
  if (mode_ == Mode::Select) {
    // One slot per detent, wrapping around; no acceleration in the carousel.
    int next = (static_cast<int>(index_) + detents) % slotCount_;
    if (next < 0) next += slotCount_;
    index_ = static_cast<uint8_t>(next);
    lastMove_ = detents > 0 ? 1 : -1;
    host_.send(out, buildSlotFocus(out, index_));
    changed();
  } else {
    host_.send(out, buildRotation(out, accelerator_.apply(detents, nowMs)));
  }
}

void Device::click() {
  if (menuOpen_) {
    menuAction(lastNowMs_);
    return;
  }
  if (slotCount_ == 0) return;
  uint8_t out[kMaxSysexBytes];
  if (mode_ == Mode::Select) {
    mode_ = Mode::Edit;
    host_.send(out, buildSlotSelect(out, index_));
  } else {
    mode_ = Mode::Select;
    host_.send(out, buildSlotLeave(out, index_));
  }
  lastMove_ = 0;
  changed();
}

void Device::tick(uint32_t nowMs) {
  lastNowMs_ = nowMs;
  if (tapPending_ && nowMs - tapAtMs_ > kDoubleTapMs) {
    tapPending_ = false;
    click();  // it stayed a single tap
  }
  if (pressed_ && !longFired_ && nowMs - pressedAtMs_ >= kLongPressMs) {
    longFired_ = true;
    longPress(nowMs);
  }
  if (menuOpen_ && nowMs - menuActivityMs_ > kMenuTimeoutMs) closeMenu();
  if (!idle_ && !knobDown_ && nowMs - lastInputMs_ >= kIdleMs) {
    idle_ = true;
    tapPending_ = false;
    changed();
  }
  if (serviceConnected_ && nowMs - lastStatusMs_ > kHeartbeatTimeoutMs) {
    serviceConnected_ = false;
    // Values are stale without the service, and nothing can be edited.
    for (uint8_t i = 0; i < slotCount_; i++) values_[i].valid = false;
    mode_ = Mode::Select;
    // The clock lives in the service; it tells us again when it is back.
    timerRunning_ = false;
    menuCount_ = 0;
    menuIndex_ = 0;
    changed();
  }
  if (timerRunning_) {
    const uint32_t seconds = timerSeconds(nowMs);
    if (seconds != timerShownSeconds_) {
      timerShownSeconds_ = seconds;
      changed();
    }
  }
  if (timerNotice_ && nowMs - timerNoticeAtMs_ > kTimerNoticeMs) {
    timerNotice_ = false;
    changed();
  }
  if (loadedNotice_ && nowMs - loadedAtMs_ > kLoadedNoticeMs) {
    loadedNotice_ = false;
    changed();
  }
}

void Device::onMessage(const uint8_t *bytes, size_t n, uint32_t nowMs) {
  lastNowMs_ = nowMs;
  static Message message;  // too large for the stack of a small task
  if (!decodeMessage(bytes, n, message)) return;
  uint8_t out[kMaxSysexBytes];

  switch (message.type) {
    case MessageType::IdentityRequest:
      host_.send(out, buildIdentityReply(out, fw_[0], fw_[1], fw_[2]));
      break;

    case MessageType::HelloRequest:
      host_.send(out, buildHello(out, fw_[0], fw_[1], fw_[2], serial_, configCrc()));
      break;

    case MessageType::ConfigBegin:
      if (message.slotCount < 1 || message.slotCount > kMaxSlots) {
        receiving_ = false;
        host_.send(out, buildConfigAck(out, 2, 0));
      } else {
        receiving_ = true;
        incomingCount_ = 0;
        incomingExpected_ = message.slotCount;
        incomingLanguage_ = message.language ? 1 : 0;
        incomingCrc_ = 0xFFFF;
      }
      break;

    case MessageType::ConfigSlot:
      if (!receiving_) break;
      if (message.index != incomingCount_ || incomingCount_ >= incomingExpected_) {
        receiving_ = false;
        host_.send(out, buildConfigAck(out, 3, 0));
      } else {
        incoming_[incomingCount_++] = message.slot;
        incomingCrc_ = crc16(message.payload, message.payloadSize, incomingCrc_);
      }
      break;

    case MessageType::ConfigEnd:
      finishConfig(message, nowMs);
      break;

    case MessageType::Value:
      if (message.index < slotCount_) {
        values_[message.index] = message.value;
        changed();
      }
      break;

    case MessageType::Status:
      statusFlags_ = message.statusFlags;
      notice_ = message.notice;
      serviceConnected_ = true;
      lastStatusMs_ = nowMs;
      changed();
      break;

    case MessageType::MenuBegin:
      receivingMenu_ = message.menuCount <= kMaxMenuItems;
      incomingItemCount_ = 0;
      incomingItemExpected_ = message.menuCount;
      incomingPage_ = message.menuPage;
      incomingSelected_ = message.menuSelected;
      memcpy(incomingTitle_, message.text, sizeof(incomingTitle_));
      break;

    case MessageType::MenuItem:
      if (!receivingMenu_) break;
      if (message.index != incomingItemCount_ || incomingItemCount_ >= incomingItemExpected_) {
        receivingMenu_ = false;
      } else {
        incomingItems_[incomingItemCount_++] = message.item;
      }
      break;

    case MessageType::MenuEnd: {
      const bool complete = receivingMenu_ && incomingItemCount_ == incomingItemExpected_;
      receivingMenu_ = false;
      if (!complete || !menuOpen_) break;  // keep what is shown
      // The same page sent again (something changed underneath) keeps the
      // line; a different page starts where the service says.
      const bool samePage = menuCount_ > 0 && strcmp(menuTitle_, incomingTitle_) == 0;
      for (uint8_t i = 0; i < incomingItemCount_; i++) menuItems_[i] = incomingItems_[i];
      menuCount_ = incomingItemCount_;
      menuPage_ = incomingPage_;
      memcpy(menuTitle_, incomingTitle_, sizeof(menuTitle_));
      if (!samePage) {
        menuIndex_ = incomingSelected_;
        lastMove_ = 0;
      }
      if (menuIndex_ >= menuCount_) menuIndex_ = 0;
      menuActivityMs_ = nowMs;
      changed();
      break;
    }

    case MessageType::TimerState: {
      timerRunning_ = message.timerRunning;
      timerJobId_ = message.timerJobId;
      timerBaseSeconds_ = message.timerElapsed;
      timerBaseMs_ = nowMs;
      timerShownSeconds_ = message.timerElapsed;
      memcpy(timerLabel_, message.text, sizeof(timerLabel_));
      changed();
      break;
    }

    case MessageType::TimerResult:
      // The action is done: the menu closes and the result is shown briefly.
      menuOpen_ = false;
      noticeCode_ = message.resultCode;
      memcpy(noticeText_, message.text, sizeof(noticeText_));
      timerNotice_ = true;
      timerNoticeAtMs_ = nowMs;
      changed();
      break;

    case MessageType::None:
      break;
  }
}

void Device::finishConfig(const Message &message, uint32_t nowMs) {
  uint8_t out[kMaxSysexBytes];
  const bool complete = receiving_ && incomingCount_ == incomingExpected_;
  receiving_ = false;
  if (!complete) {
    host_.send(out, buildConfigAck(out, 3, 0));
    return;
  }
  if (incomingCrc_ != message.crc) {
    host_.send(out, buildConfigAck(out, 1, incomingCrc_));
    return;
  }

  // Stay on the same parameter if it is still part of the configuration.
  const uint8_t previous = slotCount_ ? slots_[index_].paramId : 0;
  const bool unchanged = incomingCrc_ == configCrc() && incomingLanguage_ == language_;
  int kept = -1;
  for (uint8_t i = 0; i < incomingCount_; i++) {
    slots_[i] = incoming_[i];
    values_[i] = SlotValue();
    if (kept < 0 && incoming_[i].paramId == previous) kept = i;
  }
  slotCount_ = incomingCount_;
  language_ = incomingLanguage_;
  index_ = kept < 0 ? 0 : static_cast<uint8_t>(kept);
  if (kept < 0) mode_ = Mode::Select;
  lastMove_ = 0;

  host_.send(out, buildConfigAck(out, 0, incomingCrc_));
  if (!unchanged) {
    // The service sends its configuration on every connect; flash is only
    // written, and "loaded" only shown, when it really differs.
    store();
    loadedNotice_ = true;
    loadedAtMs_ = nowMs;
  }
  changed();
}

}  // namespace dd
