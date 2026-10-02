#include "encoder.h"

namespace dd {

void EncoderDecoder::Votes::addFirst(uint8_t reading) {
  if (count < kVotes) readings[count++] = reading;
}

void EncoderDecoder::Votes::addLast(uint8_t reading) {
  if (count == kVotes) {
    for (int i = 1; i < kVotes; i++) readings[i - 1] = readings[i];
    count--;
  }
  readings[count++] = reading;
}

int EncoderDecoder::Votes::majority() const {
  int aLow = 0;
  int bLow = 0;
  for (int i = 0; i < count; i++) {
    if (readings[i] == 1) aLow++;
    if (readings[i] == 2) bLow++;
  }
  return aLow > bLow ? 1 : bLow > aLow ? 2 : 0;
}

// Clockwise runs 0 -> 2 -> 3 -> 1 -> 0: leaving both-closed, A opens first
// and B is low last; leaving both-open, A closes first.
int EncoderDecoder::sample(uint8_t state) {
  state &= 3;
  if (state == 3) {
    if (open_ == 0) {
      before_ = last_.majority();
      taken_ = false;
    }
    open_++;
    gap_ = 0;
    if (open_ == kPassSamples && rest_ == 0 && before_) {
      passed_ = before_;
      since_.clear();
      closed_ = 0;
    }
    if (open_ >= kOpenSamples && !taken_) {
      taken_ = true;
      const int step = (rest_ == 0 && before_) ? (before_ == 2 ? 1 : -1) : 0;
      rest_ = 3;
      since_.clear();
      closed_ = 0;
      passed_ = 0;
      return step;
    }
    return 0;
  }

  if (open_ && ++gap_ > kGapSamples) open_ = 0;
  if (state != 0) {
    last_.addLast(state);
    since_.addFirst(state);
    return 0;
  }

  if (++closed_ < kClosedSamples) return 0;
  int step = 0;
  if (rest_ == 3) {
    const int first = since_.majority();
    if (first) step = first == 1 ? 1 : -1;
    rest_ = 0;
    last_.clear();
  } else if (rest_ == 0 && passed_) {
    const int first = since_.majority();
    if (first && first != passed_) {
      step = passed_ == 2 ? 2 : -2;
      last_.clear();
    }
    passed_ = 0;
  } else if (rest_ < 0) {
    rest_ = 0;
  }
  return step;
}

}  // namespace dd
