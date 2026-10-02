#include "encoder.h"

namespace dd {

int EncoderDecoder::sample(uint8_t state) {
  state &= 3;
  history_[head_] = state;
  head_ = (head_ + 1) % kHistory;
  if (stored_ < kHistory) stored_++;

  if (state == 0 || state == 3) {
    if (state == candidate_) {
      held_++;
      gap_ = 0;
    } else {
      candidate_ = state;
      held_ = 1;
      gap_ = 0;
      confirmed_ = false;
    }
  } else if (candidate_ >= 0 && ++gap_ > kGapSamples) {
    candidate_ = -1;
    held_ = 0;
  }
  if (candidate_ < 0 || held_ < kRestSamples || confirmed_) return 0;

  confirmed_ = true;
  const int previous = rest_;
  rest_ = candidate_;
  if (previous < 0 || previous == rest_) return 0;

  // Which line moved last? Look at the time before the rest began.
  int aLow = 0;  // state 1: A low, B high
  int bLow = 0;  // state 2: A high, B low
  for (int back = kRestSamples; back < stored_; back++) {
    const uint8_t s = history_[(head_ - 1 - back + 2 * kHistory) % kHistory];
    if (s == 1) aLow++;
    if (s == 2) bLow++;
  }
  if (aLow == bLow) return 0;
  // Clockwise runs 0 -> 2 -> 3 -> 1 -> 0.
  const bool viaBLow = bLow > aLow;
  return (previous == 0) == viaBLow ? 1 : -1;
}

}  // namespace dd
